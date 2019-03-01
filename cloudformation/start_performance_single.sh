#!/bin/bash -e
# Copyright (c) 2019, wso2 Inc. (http://wso2.org) All Rights Reserved.
#
# wso2 Inc. licenses this file to you under the Apache License,
# Version 2.0 (the "License"); you may not use this file except
# in compliance with the License.
# You may obtain a copy of the License at
#
# http://www.apache.org/licenses/LICENSE-2.0
#
# Unless required by applicable law or agreed to in writing,
# software distributed under the License is distributed on an
# "AS IS" BASIS, WITHOUT WARRANTIES OR CONDITIONS OF ANY
# KIND, either express or implied.  See the License for the
# specific language governing permissions and limitations
# under the License.
#
# ----------------------------------------------------------------------------
# Run all scripts.
# ----------------------------------------------------------------------------

# Cloud Formation parameters.
stack_name="is-performance-test-stack-single-node"

key_file=""
aws_access_key=""
aws_access_secret=""
certificate_name=""
jmeter_setup=""
is_setup=""
default_db_username="wso2carbon"
db_username="$default_db_username"
default_db_password="wso2carbon"
db_password="$default_db_password"
default_is_instance_type=c5.xlarge
wso2_is_instance_type="$default_is_instance_type"
default_bastion_instance_type=c5.xlarge
bastion_instance_type="$default_bastion_instance_type"

script_start_time=$(date +%s)
script_dir=$(dirname "$0")
results_dir="$PWD/results-$(date +%Y%m%d%H%M%S)"
is_performance_distribution=""
is_installer_url=""
default_minimum_stack_creation_wait_time=10
minimum_stack_creation_wait_time="$default_minimum_stack_creation_wait_time"

function usage() {
    echo ""
    echo "Usage: "
    echo "$0 -k <key_file> -a <aws_access_key> -s <aws_access_secret>"
    echo "   -c <certificate_name> -j <jmeter_setup_path>"
    echo "   [-n <is_setup_path>]"
    echo "   [-u <db_username>] [-p <db_password>]"
    echo "   [-i <wso2_is_instance_type>] [-b <bastion_instance_type>]"
    echo "   [-w <minimum_stack_creation_wait_time>] [-h]"
    echo ""
    echo "-k: The Amazon EC2 key file to be used to access the instances."
    echo "-a: The AWS access key."
    echo "-s: The AWS access secret."
    echo "-j: The path to JMeter setup."
    echo "-c: The name of the IAM certificate."
    echo "-n: The is server zip"
    echo "-u: The database username. Default: $default_db_username."
    echo "-p: The database password. Default: $default_db_password."
    echo "-i: The instance type used for IS nodes. Default: $default_is_instance_type."
    echo "-b: The instance type used for the bastion node. Default: $default_bastion_instance_type."
    echo "-w: The minimum time to wait in minutes before polling for cloudformation stack's CREATE_COMPLETE status."
    echo "    Default: $default_minimum_stack_creation_wait_time minutes."
    echo "-h: Display this help and exit."
    echo ""
}

while getopts "k:a:s:c:j:n:u:p:i:b:w:h" opts; do
    case $opts in
    k)
        key_file=${OPTARG}
        ;;
    a)
        aws_access_key=${OPTARG}
        ;;
    s)
        aws_access_secret=${OPTARG}
        ;;
    c)
        certificate_name=${OPTARG}
        ;;
    j)
        jmeter_setup=${OPTARG}
        ;;
    n)
        is_setup=${OPTARG}
        ;;
    u)
        db_username=${OPTARG}
        ;;
    p)
        db_password=${OPTARG}
        ;;
    i)
        wso2_is_instance_type=${OPTARG}
        ;;
    b)
        bastion_instance_type=${OPTARG}
        ;;
    w)
        minimum_stack_creation_wait_time=${OPTARG}
        ;;
    h)
        usage
        exit 0
        ;;
    \?)
        usage
        exit 1
        ;;
    esac
done
shift "$((OPTIND - 1))"

run_performance_tests_options="$@"

if [[ ! -f $key_file ]]; then
    echo "Please provide the key file."
    exit 1
fi

if [[ ${key_file: -4} != ".pem" ]]; then
    echo "AWS EC2 Key file must have .pem extension"
    exit 1
fi

if [[ -z $aws_access_key ]]; then
    echo "Please provide the AWS access Key."
    exit 1
fi

if [[ -z $aws_access_secret ]]; then
    echo "Please provide the AWS access secret."
    exit 1
fi

if [[ -z $db_username ]]; then
    echo "Please provide the database username."
    exit 1
fi

if [[ -z $db_password ]]; then
    echo "Please provide the database password."
    exit 1
fi

if [[ -z $jmeter_setup ]]; then
    echo "Please provide the path to JMeter setup."
    exit 1
fi

if [[ -z $certificate_name ]]; then
    echo "Please provide the name of the IAM certificate."
    exit 1
fi

if [[ -z $wso2_is_instance_type ]]; then
    echo "Please provide the AWS instance type for WSO2 IS nodes."
    exit 1
fi

if [[ -z $bastion_instance_type ]]; then
    echo "Please provide the AWS instance type for the bastion node."
    exit 1
fi

if [[ -z $is_setup ]]; then
    echo "Please provide is zip file path."
    exit 1
fi

if ! [[ $minimum_stack_creation_wait_time =~ ^[0-9]+$ ]]; then
    echo "Please provide a valid minimum time to wait before polling for cloudformation stack's CREATE_COMPLETE status."
    exit 1
fi

key_filename=$(basename $key_file)
key_name=${key_filename%.*}

function check_command() {
    if ! command -v $1 >/dev/null 2>&1; then
        echo "Please install $1"
        exit 1
    fi
}

# Checking for the availability of commands in jenkins.
check_command bc
check_command aws
check_command unzip
check_command jq
check_command python

function format_time() {
    # Duration in seconds
    local duration="$1"
    local minutes=$(echo "$duration/60" | bc)
    local seconds=$(echo "$duration-$minutes*60" | bc)
    if [[ $minutes -ge 60 ]]; then
        local hours=$(echo "$minutes/60" | bc)
        minutes=$(echo "$minutes-$hours*60" | bc)
        printf "%d hour(s), %02d minute(s) and %02d second(s)\n" $hours $minutes $seconds
    elif [[ $minutes -gt 0 ]]; then
        printf "%d minute(s) and %02d second(s)\n" $minutes $seconds
    else
        printf "%d second(s)\n" $seconds
    fi
}

function measure_time() {
    local end_time=$(date +%s)
    local start_time=$1
    local duration=$(echo "$end_time - $start_time" | bc)
    echo "$duration"
}

mkdir $results_dir
echo ""
echo "Results will be downloaded to $results_dir"

echo ""
echo "Extracting IS Performance Distribution to $results_dir"
tar -xf ../distribution/target/is-performance-distribution-*.tar.gz -C $results_dir

home="$results_dir/setup/single-node-setup"


echo $home

estimate_command="$results_dir/jmeter/run-performance-tests.sh -t ${run_performance_tests_options[@]}"
echo ""
echo "Estimating time for performance tests: $estimate_command"
# Estimating this script will also validate the options. It's important to validate options before creating the stack.
$estimate_command

temp_dir=$(mktemp -d)


# Get absolute paths
key_file=$(realpath $key_file) 

echo "your key is"
echo $key_file


ln -s $key_file $temp_dir/$key_filename

cd $script_dir

echo ""
echo "Validating stack..."
aws cloudformation validate-template --template-body file://singlenode/single-node.yaml

# Save metadata
test_parameters_json='.'
test_parameters_json+=' | .["is_nodes_ec2_instance_type"]=$is_nodes_ec2_instance_type'
test_parameters_json+=' | .["bastion_node_ec2_instance_type"]=$bastion_node_ec2_instance_type'
jq -n \
    --arg is_nodes_ec2_instance_type "$wso2_is_instance_type" \
    --arg bastion_node_ec2_instance_type "$bastion_instance_type" \
    "$test_parameters_json" > $results_dir/cf-test-metadata.json

stack_create_start_time=$(date +%s)
create_stack_command="aws cloudformation create-stack --stack-name $stack_name \
    --template-body file://singlenode/single-node.yaml --parameters \
        ParameterKey=AWSAccessKeyId,ParameterValue=$aws_access_key \
        ParameterKey=AWSAccessKeySecret,ParameterValue=$aws_access_secret \
        ParameterKey=CertificateName,ParameterValue=$certificate_name \
        ParameterKey=KeyPairName,ParameterValue=$key_name \
        ParameterKey=DBUsername,ParameterValue=$db_username \
        ParameterKey=DBPassword,ParameterValue=$db_password \
        ParameterKey=WSO2InstanceType,ParameterValue=$wso2_is_instance_type \
        ParameterKey=BastionInstanceType,ParameterValue=$bastion_instance_type \
    --capabilities CAPABILITY_IAM"

echo ""
echo "Creating stack..."
echo "$create_stack_command"
stack_id="$($create_stack_command)"
stack_id=$(echo $stack_id|jq -r .StackId)

echo ""
echo "Waiting ${minimum_stack_creation_wait_time}m before polling for cloudformation stack's CREATE_COMPLETE status..."
sleep ${minimum_stack_creation_wait_time}m

echo ""
echo "Polling till the stack creation completes..."
aws cloudformation wait stack-create-complete --stack-name $stack_id
printf "Stack creation time: %s\n" "$(format_time $(measure_time $stack_create_start_time))"

echo ""
echo "Getting Bastion Node Public IP..."
bastion_instance="$(aws cloudformation describe-stack-resources --stack-name $stack_id --logical-resource-id WSO2BastionInstance2 | jq -r '.StackResources[].PhysicalResourceId')"
bastion_node_ip="$(aws ec2 describe-instances --instance-ids $bastion_instance | jq -r '.Reservations[].Instances[].PublicIpAddress')"
echo "Bastion Node Public IP: $bastion_node_ip"


echo ""
echo "Getting WSO2 IS Node Private IP..."
wso2is1_auto_scaling_grp="$(aws cloudformation describe-stack-resources --stack-name $stack_id --logical-resource-id WSO2ISNode1AutoScalingGroup | jq -r '.StackResources[].PhysicalResourceId')"
wso2is1_instance="$(aws autoscaling describe-auto-scaling-groups --auto-scaling-group-names $wso2is1_auto_scaling_grp | jq -r '.AutoScalingGroups[].Instances[].InstanceId')"
wso2_is_1_ip="$(aws ec2 describe-instances --instance-ids $wso2is1_instance | jq -r '.Reservations[].Instances[].PrivateIpAddress')"
echo "WSO2 IS Node Private IP: $wso2_is_1_ip"

echo ""
echo "Getting RDS Hostname..."
rds_instance="$(aws cloudformation describe-stack-resources --stack-name $stack_id --logical-resource-id WSO2ISDBInstance2 | jq -r '.StackResources[].PhysicalResourceId')"
rds_host="$(aws rds describe-db-instances --db-instance-identifier $rds_instance | jq -r '.DBInstances[].Endpoint.Address')"
echo "RDS Hostname: $rds_host"

copy_isserver_edit_command="scp -i $key_file -o "StrictHostKeyChecking=no" $home/isserver_edit.sh ubuntu@$bastion_node_ip:/home/ubuntu/"
copy_isserver_setups_command="scp -r -i $key_file -o "StrictHostKeyChecking=no" $home/setup ubuntu@$bastion_node_ip:/home/ubuntu/"
copy_is_server_command="scp -i $key_file -o "StrictHostKeyChecking=no" $is_setup ubuntu@$bastion_node_ip:/home/ubuntu/wso2is.zip"
copy_is_master_setup_command="scp -i $key_file -o "StrictHostKeyChecking=no" $home/setup_is.sh ubuntu@$bastion_node_ip:/home/ubuntu/"
copy_key_file_command="scp -i $key_file -o "StrictHostKeyChecking=no" $key_file ubuntu@$bastion_node_ip:/home/ubuntu/private_key.pem"
copy_db_create_command="scp -i $key_file -o "StrictHostKeyChecking=no" $home/createDB.sql ubuntu@$bastion_node_ip:/home/ubuntu/"
copy_connector_command="scp -i $key_file -o "StrictHostKeyChecking=no" mysql-connector-java-5.1.47.jar ubuntu@$bastion_node_ip:/home/ubuntu/"

echo ""
echo "Copying Is server setup files..."
echo $copy_isserver_edit_command
$copy_isserver_edit_command
echo $copy_isserver_setups_command
$copy_isserver_setups_command
echo $copy_is_server_command
$copy_is_server_command
echo $copy_is_master_setup_command
$copy_is_master_setup_command
echo $copy_key_file_command
$copy_key_file_command
echo $copy_db_create_command
$copy_db_create_command
echo copy_connector_command
$copy_connector_command

setup_is_command="ssh -i $key_file -o "StrictHostKeyChecking=no" -t ubuntu@$bastion_node_ip ./setup_is.sh -n $wso2_is_1_ip -r $rds_host"

echo ""
echo "Running IS node setup script: $setup_is_command"
# Handle any error and let the script continue.
$setup_is_command || echo "Remote ssh command to setup is node through bastion failed."

copy_bastion_setup_command="scp -i $key_file -o StrictHostKeyChecking=no $results_dir/setup/setup-bastion.sh ubuntu@$bastion_node_ip:/home/ubuntu/"
copy_jmeter_setup_command="scp -i $key_file -o StrictHostKeyChecking=no $jmeter_setup ubuntu@$bastion_node_ip:/home/ubuntu/"
copy_repo_setup_command="scp -i $key_file -o "StrictHostKeyChecking=no" ../distribution/target/is-performance-distribution-*.tar.gz ubuntu@$bastion_node_ip:/home/ubuntu"

echo ""
echo "Copying files to Bastion node..."
echo $copy_bastion_setup_command
$copy_bastion_setup_command
echo $copy_jmeter_setup_command
$copy_jmeter_setup_command
echo $copy_repo_setup_command
$copy_repo_setup_command

setup_bastion_node_command="ssh -i $key_file -o "StrictHostKeyChecking=no" -t ubuntu@$bastion_node_ip sudo ./setup-bastion.sh -w $wso2_is_1_ip  -l $wso2_is_1_ip -r $rds_host"
echo ""
echo "Running Bastion Node setup script: $setup_bastion_node_command"
# Handle any error and let the script continue.
$setup_bastion_node_command || echo "Remote ssh command failed."

run_performance_tests_command="./workspace/jmeter/run-performance-tests.sh"
run_remote_tests="ssh -i $key_file -o "StrictHostKeyChecking=no" -t ubuntu@$bastion_node_ip $run_performance_tests_command"
echo ""
echo "Running performance tests: $run_remote_tests"
$run_remote_tests || echo "Remote test ssh command failed."

download="scp -i $key_file -o "StrictHostKeyChecking=no" ubuntu@$bastion_node_ip:/home/ubuntu/results.zip $results_dir/"
echo "Running command: $download"
$download || echo "Remote download failed"

if [[ ! -f $results_dir/results.zip ]]; then
    echo ""
    echo "Failed to download the results.zip"
    exit 500
fi

echo ""
echo "Creating unzipping results..."
cd $results_dir
unzip -q results.zip
echo ""
echo "Done."
