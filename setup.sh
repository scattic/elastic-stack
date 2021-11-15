#!/bin/bash

YEL='\033[1;33m'
RED='\033[0;31m'
GRN='\033[1;32m'
NC='\033[0m' # No Color

INFO=1
ERROR=2
INPUT=3

write_message() {
# expects 2 args: type (INFO or ERROR) and the message string
  if [ $1 -eq $INFO ]; then
    echo -e "${YEL} - ${2} ${NC}"
    return
  fi
  if [ $1 -eq $ERROR ]; then
    echo -e "${RED}(!) ${2} ${NC}"
    return
  fi
  if [ $1 -eq $INPUT ]; then
    echo -e "${GRN}>>> ${2} ${NC}"
    return
  fi
}

write_message $INFO "Checking for root"
if [[ $EUID -ne 0 ]]; then
   write_message $ERROR "Must run as root. Try again."
   exit 1
fi

write_message $INFO "Installing missing prerequisite system packages"

apt install --no-upgrade docker.io docker-compose curl

result=$?
if [ $result -ne 0 ]; then
    write_message $ERROR "Error while installing required packages."
    exit 1
fi

# basic sanity check, could be improved to check for all key files, just check for folders and assume contents are correct

write_message $INFO "Performing basic source sanity tests"

for srcdir in portainer certs elasticsearch kibana fleet
do
  if [[ ! -d $srcdir ]]; then
    write_message $ERROR "folder ${srcdir} is missing"
    exit 1
  fi
done

# ------------------------ Cleanup --------------------------

if [[ $1 == "reset" ]]; then
  write_message $INFO "Cleaning up and deleting ALL THE DATA..."
  echo
  write_message $INFO "!!!!! WARNING WARNING WARNING !!!!!"
  echo
  write_message $INFO "This action will destroy all the collected data and containers, configurations and credentials. Any deployed agents will no longer be able to communicate (ever) and will have to be redeployed."
  echo
  read -p "Are you sure you want to remove all the containers and data and start fresh? " -n 1 -r
  echo
  if [[ $REPLY =~ ^[Yy]$ ]]
  then
    
    cd kibana && pwd 
    docker-compose down -v 
    rm docker-compose.yml 
    cd ..
    
    cd fleet && pwd
    docker-compose down -v 
    rm docker-compose.yml 
    cd ..
    
    cd agent && pwd 
    docker-compose down -v 
    rm docker-compose.yml
    cd ..
    
    cd elasticsearch && pwd 
    docker-compose down -v 
    cd ..
    
    cd certs && pwd 
    rm ca.crt passwords creds.txt 
    cd ..
    
    cd portainer && pwd 
    docker-compose down -v 
    cd ..
    pwd
    
  fi    
fi

# ------------------------ Portainer ------------------------

write_message $INFO "Deploying PORTAINER if needed"

cd ./portainer && [ ! "$(docker-compose top portainer | grep portainer)" ] 

result=$?
if [ $result -eq 0 ]; then
   write_message $INFO "PORTAINER is not running, will deploy it now"
   docker-compose up -d 
fi

SERVICE="http://localhost:9000"
for attempt in {0..10}
do
  write_message $INFO "Waiting for PORTAINER to start, attempt ${attempt}/10"
  curl -f $SERVICE -o /dev/null -s
  result=$?
  if [ $result -eq 0 ]; then
    break 2
  fi
  sleep 10
done

if [ $attempt -eq 10 ]; then
  write_message $ERROR "PORTAINER did not start. Will now quit."
  exit 1
fi

write_message $INFO "PORTAINER is now running on ${SERVICE}. You will need to configure the user and password when first opened."
cd ..

# ------------------------ Elasticsearch ------------------------

write_message $INFO "Generating certificates if needed" 

#TODO: assumption of small lab deployment; for production deployments we assume an HAProxy with SSL termination will be 

if [[ ! -f ./certs/ca.crt ]]; then # certs must be generated 
  cd ./elasticsearch 
  docker-compose -f setup-certs.yml down -v 
  docker-compose -f setup-certs.yml up
  cd ..
  docker cp create_certs:/certs/ca/ca.crt ./certs
  docker rm create_certs
fi

write_message $INFO "Deploying ELASTICSEARCH if needed" 

cd ./elasticsearch && [ ! "$(docker-compose top elasticsearch | grep elasticsearch)" ] 

result=$?
if [ $result -eq 0 ]; then
   write_message $INFO "ELASTICSEARCH is not running, will deploy it now"
   docker-compose up -d 
fi

SERVICE="https://localhost:9200"
for attempt in {0..10}
do
  write_message $INFO "Waiting for ELASTICSEARCH to start, attempt ${attempt}/10"
  curl --cacert ../certs/ca.crt -u elastic:changeme https://localhost:9200 -s | grep "unable to authenticate" # this will error out
  result=$?
  if [ $result -eq 0 ]; then
    break 2
  fi
  sleep 10
done
if [ $attempt -eq 10 ]; then
  write_message $ERROR "ELASTICSEARCH did not start. Will now quit."
  exit 1
fi

if [[ ! -f ../certs/creds.txt ]]; then
  write_message $INFO "Generating ELASTICSEARCH credentials" 
  sudo docker-compose exec -u root elasticsearch /bin/bash -c "bin/elasticsearch-setup-passwords auto --batch --url https://localhost:9200" > ../certs/creds.txt
fi

if [[ -f ../certs/creds.txt ]]; then  
  write_message $INFO "Importing ELASTICSEARCH credentials"
  cat ../certs/creds.txt | grep PASSWORD | sed 's/PASSWORD /password_/g' | sed 's/ //g' | sed 's/\r//g' > ../certs/passwords
  source ../certs/passwords
  write_message $INFO "Login with user: [elastic] and password: '${password_elastic}'" 
fi

cd .. 
curl -s --cacert certs/ca.crt -u elastic:${password_elastic} https://localhost:9200/ | grep "You Know, for Search"
result=$?
if [ ! $result -eq 0 ]; then
  write_message $ERROR "Cannot establish an authenticated connection to ELASTICSEARCH. Will now quit."
  exit 1
fi

curl -s -X GET --cacert certs/ca.crt -u elastic:${password_elastic} https://localhost:9200/_cluster/health?pretty

# ------------------------ Kibana ------------------------

write_message $INFO "Deploying KIBANA if needed" 

cd ./kibana && [ ! "$(docker-compose top kibana | grep kibana)" ] 

result=$?
if [ $result -eq 0 ]; then
   write_message $INFO "KIBANA is not running, will deploy it now"
   
   write_message $INFO "Generating KIBANA docker-compose file" 
   cp docker-compose.template docker-compose.yml
   TMP="s/CHANGEME/${password_kibana_system}/g"
   sed -i $TMP docker-compose.yml
   
   #TODO: generate random encryption key for objects, at the moment it is hardcoded in kibana.yml
   
   docker-compose up -d 
fi

SERVICE="https://localhost:5601/login"
for attempt in {0..10}
do
  write_message $INFO "Waiting for KIBANA to start, attempt ${attempt}/10"
  curl -s --cacert ../certs/ca.crt $SERVICE | grep "<title>Elastic" # this will error out
  result=$?
  if [ $result -eq 0 ]; then
    break 2
  fi
  sleep 10
done
if [ $attempt -eq 10 ]; then
  write_message $ERROR "KIBANA did not start. Will now quit."
  exit 1
fi

cd ..

echo
write_message $INPUT "ATTENTION: A manual configuration step is now required."
echo
write_message $INPUT "1) Open Kibana, go to Fleet and open Fleet Settings."
write_message $INFO "    Kibana user: [elastic] and password: [${password_elastic}]" 
write_message $INPUT "2) Set the Fleet server host to: http://fleet:8220"
write_message $INPUT "3) Set the Elasticsearch host to: https://elasticsearch:9200"
write_message $INPUT "4) Click on [Save and Apply settings] and [Apply settings]"
write_message $INPUT "Press ENTER when done and installation will continue."
read

# ------------------------ Fleet ------------------------

write_message $INFO "Deploying FLEET server if needed"

cd ./fleet && [ ! "$(docker-compose top fleet | grep fleet)" ] 

result=$?
if [ $result -eq 0 ]; then
   write_message $INFO "FLEET server is not running, will deploy it now"

   cp docker-compose.template docker-compose.yml
   TMP="s/REPLACE1/${password_elastic}/g"
   sed -i $TMP docker-compose.yml
      
   docker-compose up -d 
   
   sleep 15

   write_message $INFO "Adding trusted CA to FLEET"

   docker-compose exec -u root fleet /bin/bash -c "update-ca-trust force-enable"
   docker-compose exec -u root fleet /bin/bash -c "cp /usr/share/elasticsearch/config/certificates/ca/ca.crt /etc/pki/ca-trust/source/anchors/"
   docker-compose exec -u root fleet /bin/bash -c "update-ca-trust extract"

   sleep 15

   docker-compose stop && docker-compose up -d
   
   write_message $INFO "FLEET deployed" 
fi

SERVICE="http://localhost:8220"
for attempt in {0..10}
do
  write_message $INFO "Waiting for FLEET to start, attempt ${attempt}/10"
  curl -s $SERVICE | grep "404" # this will error out
  result=$?
  if [ $result -eq 0 ]; then
    break 2
  fi
  sleep 10
done
if [ $attempt -eq 10 ]; then
  write_message $ERROR "FLEET did not start. Will now quit."
  exit 1
fi

cd ..

# ------------------------ Agent ------------------------

write_message $INFO "Deploying AGENT server if needed"

cd ./agent && [ ! "$(docker-compose top agent | grep agent)" ] 

result=$?
if [ $result -eq 0 ]; then

   write_message $INFO "AGENT is not running, will deploy it now"
   echo
   write_message $INPUT "ATTENTION: A manual configuration step is now required."
   write_message $INPUT "1) Open Kibana, then go to Management section, Fleet -> Enrollment tokens, then click on the View icon (eye) of the Default policy"
   write_message $INFO "    Kibana user: [elastic] and password: [${password_elastic}]" 
   write_message $INPUT "2) Copy the token and paste it below"
   
   echo
   read -p "Enter enrollment token: " token
   
   write_message $INFO "Generating AGENT docker-compose file" 
   cp docker-compose.template docker-compose.yml
   TMP="s/REPLACE1/${password_elastic}/g"
   sed -i $TMP docker-compose.yml
   TMP="s/REPLACE2/${token}/g"
   sed -i $TMP docker-compose.yml
   
   docker-compose up -d
   
   sleep 15

   write_message $INFO "Adding trusted CA to AGENT"
   
   docker-compose exec -u root agent /bin/bash -c "update-ca-trust force-enable"
   docker-compose exec -u root agent /bin/bash -c "cp /usr/share/elasticsearch/config/certificates/ca/ca.crt /etc/pki/ca-trust/source/anchors/"
   docker-compose exec -u root agent /bin/bash -c "update-ca-trust extract"
   docker-compose exec -u root agent /bin/bash -c "elastic-agent restart"
   
   write_message $INFO "AGENT deployed" 
fi

cd ..

# ------------------------ Agent ------------------------

write_message $INFO "Deployment is now complete. Enjoy."

