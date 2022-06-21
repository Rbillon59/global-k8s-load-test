#!/bin/bash

# Exit on any non zero exit code
set -e

#=== FUNCTION ================================================================
#        NAME: logit
# DESCRIPTION: Log into file and screen.
# PARAMETER - 1 : Level (ERROR, INFO, WARN)
#           - 2 : Message
#
#===============================================================================
logit()
{
    case "$1" in
        "INFO")
            echo -e " [\e[94m $1 \e[0m] [ $(date '+%d-%m-%y %H:%M:%S') ] $2 \e[0m" ;;
        "WARN")
            echo -e " [\e[93m $1 \e[0m] [ $(date '+%d-%m-%y %H:%M:%S') ]  \e[93m $2 \e[0m " && sleep 2 ;;
        "ERROR")
            echo -e " [\e[91m $1 \e[0m] [ $(date '+%d-%m-%y %H:%M:%S') ]  $2 \e[0m " ;;
    esac
}

#=== FUNCTION ================================================================
#        NAME: usage
# DESCRIPTION: Helper of the function
# PARAMETER - None
#
#===============================================================================
usage()
{
  echo "-s <path_to_service_account_file>"
  echo "-p <gcp_project_id>"
  echo "-d flag to delete all the instances"
  echo "-k <gcp_ssh_key_path> absolute path to the ssh key used to reach GCP compute instances"
  echo "-u <gcp_ssh_user> the user used to ssh into the compute instances"
  echo "-j JMeter scenario name. Basically, the name of the folder child of scenario"
  exit 1
}



############################
# Script arguments parsing #
############################

while getopts 'hs:p:dk:u:j:' option;
    do
      case $option in
        s	)	service_account_path="${OPTARG}"  ;;
        p   )   gcp_project_id="${OPTARG}" ;;
        k   )   gcp_ssh_key_path="${OPTARG}" ;;
        u   )   gcp_ssh_user="${OPTARG}" ;;
        j   )   jmeter_scenario_name="${OPTARG}" ;;
        d   )   delete=1 ;;
        h   )   usage ;;
        ?   )   usage ;;
      esac
done

if [ -z "${jmeter_scenario_name}" ]; then
    logit "ERROR" "Please provide the jmeter scenario folder to use"
    usage
    exit 1
fi

if [ ! -f "${PWD}/scenario/${jmeter_scenario_name}/.env" ]; then
    logit "ERROR" "Unable to open ${PWD}/scenario/${jmeter_scenario_name}/.env"
    exit 1
fi

source "${PWD}/scenario/${jmeter_scenario_name}/.env"

if [ -z "${ZONES}" ]; then
    logit "ERROR" "The ZONES need to be set in the .env file of your scenario. It will define where to provision GCP instances"
    exit 1
fi

if [ -z "${MACHINE_TYPE}" ]; then
    logit "WARN" "MACHINE_TYPE variable not set, applying default : e2-standard-4"
    MACHINE_TYPE="e2-standard-4"
fi

if [ -z "${NETWORK_NAME}" ]; then
    logit "WARN" "NETWORK_NAME variable not set, applying default : k3s-network"
    NETWORK_NAME="k3s-network"
fi

if [ -z "${MACHINE_NETWORK_TAG}" ]; then
    logit "WARN" "MACHINE_NETWORK_TAG variable not set, applying default : k3s"
    MACHINE_NETWORK_TAG="k3s"
fi

if [ -z "${MACHINE_DISK_SIZE}" ]; then
    logit "WARN" "MACHINE_DISK_SIZE variable not set, applying default : 10G"
    MACHINE_DISK_SIZE="10GB"
fi

####################
# Parameters check #
####################

if [ "$#" -eq 0 ]
  then
    usage
fi

if [ -z "${gcp_project_id}" ]; then
    logit "ERROR" "Provide the GCP Project ID please"
    usage
    exit 1
fi

if [ -z "${service_account_path}" ]; then
    logit "ERROR" "Provide the path to the service account json file"
    usage
    exit 1
fi

if [ -z "${gcp_ssh_key_path}" ]; then
    logit "ERROR" "Provide the path to the ssh-key used to ssh into compute instances"
    usage
    exit 1
fi

if [ -z "${gcp_ssh_user}" ]; then
    logit "ERROR" "Provide the user used to ssh GCP compute instances"
    usage
    exit 1
fi

# GCP authentication
gcloud auth activate-service-account --key-file "${service_account_path}"

if [ -n "${delete}" ]; then
    logit "WARN" "Instances deletion enable.. The deletion will start in 5 seconds"
    sleep 5
    for zone in "${ZONES[@]}"; do
        logit "INFO" "Deleting instance-${zone}"
        gcloud compute instances delete --project="${gcp_project_id}" --zone="${zone}" --quiet "instance-${zone}" &
    done
    wait
    logit "INFO" "All instances have been deleted"
    exit 0

fi


logit "INFO" "Checking if the ${NETWORK_NAME} network exist"
if [ "$(gcloud --project="${gcp_project_id}" --format "value(name)" compute networks list --filter=name=${NETWORK_NAME})" != "${NETWORK_NAME}" ]; then

    logit "INFO" "${NETWORK_NAME} network don't exist creating it"

    logit "INFO" "#############################################"
    logit "INFO" "Creating the network and firewall rules"
    logit "INFO" "#############################################"

    logit "INFO" "Creating a specific VPC for the instances"
    gcloud compute networks create "${NETWORK_NAME}" --project="${gcp_project_id}" --subnet-mode=auto --mtu=1460 --bgp-routing-mode=global

    logit "INFO" "Applying firewall rules to the VPC to allow instances peering inside the k3s cluster"

    logit "WARN" "Opening all ports to all k3s instances"
    gcloud compute --project=${gcp_project_id} firewall-rules create allow-all --direction=INGRESS --priority=1000 --network=${NETWORK_NAME} --action=ALLOW --rules=all --source-ranges=0.0.0.0/0 --target-tags=${MACHINE_NETWORK_TAG}
else
    logit "INFO" "Network ${NETWORK_NAME} already exist, skipping network creation"
fi

# Provisionning GCP instances
logit "INFO" "#############################################"
logit "INFO" "Starting the instances provisionning in GCP"
logit "INFO" "#############################################"
sleep 2

for zone in "${ZONES[@]}"; do
    logit "INFO" "Provisionning an instance ${MACHINE_TYPE} in ${zone}"
    gcloud beta compute --project="${gcp_project_id}" instances create \
    "instance-${zone}" \
    --zone="${zone}" \
    --machine-type="${MACHINE_TYPE}" \
    --subnet="${NETWORK_NAME}" \
    --network-tier=PREMIUM \
    --no-restart-on-failure \
    --preemptible \
    --tags="${MACHINE_NETWORK_TAG}" \
    --boot-disk-size=10GB \
    --boot-disk-type=pd-balanced &
done
wait 
logit "INFO" "All instances are up and running"

logit "INFO" "#############################################"
logit "INFO" "Creating the Kubernetes cluster with k3sup"
logit "INFO" "#############################################"
sleep 2

if [ ! -f "./k3sup" ]; then
    logit "INFO" "Getting k3sup project"
    curl -sLS https://get.k3sup.dev | sh
fi

logit "INFO" "Deploying the master node"
logit "WARN" "The master will always be the instance inside the first zone inside the ZONES array"
export MASTER_IP=$(gcloud --project="${gcp_project_id}" --format="value(networkInterfaces[0].accessConfigs[0].natIP)" compute instances list --filter="name=(instance-${ZONES[0]})")

logit "INFO" "Waiting SSH port to be open on master node instance-${ZONES[0]} on Public IP ${MASTER_IP}"

while : ; do
    if echo 'test open port 22' 2>/dev/null > "/dev/tcp/${MASTER_IP}/22"; then echo "SSH port open on master node instance-${ZONES[0]} on Public IP ${MASTER_IP}"; break; fi
    sleep 1
done

install_success=1
while [ ${install_success} -ne 0 ] ; do
    sleep 1
    ./k3sup install --ip "${MASTER_IP}" \
        --local-path "./master-node-config" \
        --ssh-key "${gcp_ssh_key_path}" \
        --user "${gcp_ssh_user}"
        
    install_success=$?
done




for zone in "${ZONES[@]}"; do
    if [ "${zone}" != "${ZONES[0]}" ]; then
        logit "INFO" "Deploying k3s agent node in instance-${zone}"
        export AGENT_IP=$(gcloud --project="${gcp_project_id}" --format="value(networkInterfaces[0].accessConfigs[0].natIP)" compute instances list --filter="name=(instance-${zone})")

        logit "INFO" "Waiting SSH port to be open on agent node instance-${zone} on Public IP ${AGENT_IP}"
        while : ; do
            if echo 'test open port 22' 2>/dev/null > "/dev/tcp/${AGENT_IP}/22"; then echo "SSH port open on master node instance-${zone} on Public IP ${AGENT_IP}"; break; fi
            sleep 1
        done

        ./k3sup join --ip "${AGENT_IP}" \
            --server-ip "${MASTER_IP}" \
            --ssh-key "${gcp_ssh_key_path}" \
            --user "${gcp_ssh_user}" &
    fi
done

wait 
logit "INFO" "All agents have been provisionned and installed"
logit "INFO" "Checking if everything is working"
export KUBECONFIG="$PWD/master-node-config"

expected_node_number=${#ZONES[@]}
current_node_number=0

while [ ${current_node_number} -ne $((expected_node_number +1)) ]; do
    kubectl get nodes -o wide
    current_node_number=$(kubectl get nodes -o wide | wc -l)
    sleep 5
done

logit "INFO" "Succesfully deployed the k3s cluster all over the world"


logit "INFO" "#############################################"
logit "INFO" "Deploying the JMeter stack on the cluster"
logit "INFO" "#############################################"
sleep 2

kubectl create -R -f k8s/

logit "INFO" "Before starting your test, type export KUBECONFIG=$PWD/master-node-config"
logit "INFO" "Now you can run the ./start_test script to run your performance test"


