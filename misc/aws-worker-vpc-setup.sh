#! /bin/bash

set -e

for region in us-{west,east}-{1,2}; do
    echo "region $region:"

    vpcId=$(aws ec2 describe-vpcs --region $region --filter Name=tag:Name,Values=community-workers | jq -r '.Vpcs[0].VpcId')
    if [ "$vpcId" = "null" ]; then
        vpcId=$(aws ec2 create-vpc --region $region --cidr-block 10.0.0.0/16 | jq -r '.Vpc.VpcId')
        aws ec2 create-tags --region $region --resources $vpcId --tags Key=Name,Value=community-workers
    fi
    echo " vpcId: $vpcId"

    igwId=$(aws ec2 describe-internet-gateways --region $region --filter Name=tag:Name,Values=community-workers | jq -r '.InternetGateways[0].InternetGatewayId')
    if [ "$igwId" = "null" ]; then
        igwId=$(aws ec2 create-internet-gateway --region $region | jq -r '.InternetGateway.InternetGatewayId')
        aws ec2 create-tags --region $region --resources $igwId --tags Key=Name,Value=community-workers
        aws ec2 attach-internet-gateway --region $region --internet-gateway-id $igwId --vpc-id $vpcId
    fi
    echo " igwId: $igwId"

    # this is created automatically for the VPC
    routeTableId=$(aws ec2 describe-route-tables --region $region --filter Name=vpc-id,Values=$vpcId | jq -r '.RouteTables[0].RouteTableId')
    if [ "$routeTableId" != "null" ]; then
        aws ec2 create-route --region $region --route-table-id $routeTableId --gateway-id $igwId --destination-cidr-block 0.0.0.0/0
        aws ec2 create-tags --region $region --resources $routeTableId --tags Key=Name,Value=community-workers
    else
        echo " could not find associated route table for vpcId: $vpcId"
        exit 1
    fi
    echo " routeTableId: $routeTableId"

    echo " subnets by AZ":
    cidr=0
    for az in $(aws ec2 describe-availability-zones --region $region | jq -r '.AvailabilityZones[] | .ZoneName'); do
        subnetId=$(aws ec2 describe-subnets --region $region --filter "[{\"Name\": \"vpc-id\", \"Values\": [\"${vpcId}\"]}, {\"Name\": \"availability-zone\", \"Values\": [\"${az}\"]}]" | jq -r '.Subnets[0].SubnetId')
        if [ "$subnetId" = "null" ]; then
            subnetId=$(aws ec2 create-subnet --region $region --vpc-id $vpcId --availability-zone $az --cidr-block 10.0.$cidr.0/20 | jq -r '.Subnet.SubnetId')
            aws ec2 create-tags --region $region --resources $subnetId --tags Key=Name,Value=community-workers
        fi
        echo "  $az: $subnetId"
        cidr=$((cidr + 16))
    done

    echo " security groups":
    for name in no-inbound docker-worker; do
        groupId=$(aws ec2 describe-security-groups --region $region --filter "[{\"Name\": \"vpc-id\", \"Values\": [\"${vpcId}\"]}, {\"Name\": \"group-name\", \"Values\": [\"${name}\"]}]" | jq -r '.SecurityGroups[0].GroupId')
        if [ "$groupId" = "null" ]; then
            groupId=$(aws ec2 create-security-group --region $region --description $name --group-name $name --vpc-id $vpcId | jq -r ".GroupId")
            aws ec2 create-tags --region $region --resources $groupId --tags Key=Name,Value=community-workers

            case $name in
                no-inbound)
                    # security groups do not allow inbound traffic by default, so nothing to do..
                    ;;
                docker-worker)
                    # docker-worker allows incoming non-priv ports for livelog
                    aws ec2 authorize-security-group-ingress --region $region --group-id $groupId --protocol tcp --port 32768-65535 --cidr 0.0.0.0/0
                    ;;
            esac
        fi

        echo "  $name: $groupId"
    done
done
