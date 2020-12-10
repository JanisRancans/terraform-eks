###############################################################################
################################ DATA SOURCES #################################
###############################################################################

variable "cluster_name" {
  default = "test-cluster"
}

# Search for latest Ubuntu server image
data "aws_ami" "ubuntu_latest" {
  most_recent = true
  owners      = ["099720109477"] # Canonical

  filter {
    name   = "name"
    values = ["ubuntu/images/hvm-ssd/ubuntu-*-*.*-amd64-server-*"]
  }

  filter {
    name   = "virtualization-type"
    values = ["hvm"]
  }
}

# Search for instance type
data "aws_ec2_instance_type_offering" "ubuntu_micro" {
  filter {
    name   = "instance-type"
    values = ["t2.medium"]
  }

  preferred_instance_types = ["t3.medium"]
}

# Availability zones data source to get list of AWS Availability zones
data "aws_availability_zones" "available" {
  state = "available"
}

###############################################################################
################################### VPC #######################################
###############################################################################

module "vpc" {
  source = "terraform-aws-modules/vpc/aws"
  name   = "test-vpc"

  cidr            = "10.0.0.0/16"
  azs             = data.aws_availability_zones.available.names
  private_subnets = ["10.0.1.0/24", "10.0.2.0/24", "10.0.3.0/24"]
  public_subnets  = ["10.0.101.0/24", "10.0.102.0/24", "10.0.6.0/24"]

  enable_dns_hostnames = true
  enable_dns_support   = true
  enable_nat_gateway   = true
  single_nat_gateway   = true

  tags = {
    "kubernetes.io/cluster/${var.cluster_name}" = "shared"
  }

  public_subnet_tags = {
    "kubernetes.io/cluster/${var.cluster_name}" = "shared"
    "kubernetes.io/role/elb"                    = "1"
  }

  private_subnet_tags = {
    "kubernetes.io/cluster/${var.cluster_name}" = "shared"
    "kubernetes.io/role/internal-elb"           = "1"
    "k8s.io/cluster-autoscaler/enabled"         = true
    "k8s.io/cluster-autoscaler/jupyterhub"      = "owned"

  }

}

###############################################################################
############################### HERE BE DRAGONS ###############################
###############################################################################

data "aws_eks_cluster" "cluster" {
  name = module.eks.cluster_id
}

data "aws_eks_cluster_auth" "cluster" {
  name = module.eks.cluster_id
}

data "tls_certificate" "cert" {
  url = data.aws_eks_cluster.cluster.identity[0].oidc[0].issuer
}

resource "aws_iam_openid_connect_provider" "openid_connect" {
  client_id_list  = ["sts.amazonaws.com"]
  thumbprint_list = [data.tls_certificate.cert.certificates.0.sha1_fingerprint]
  url             = data.aws_eks_cluster.cluster.identity[0].oidc[0].issuer
}

module "ebs_csi_driver_controller" {
  source = "DrFaust92/ebs-csi-driver/kubernetes"
  # version = "<VERSION>"

  ebs_csi_controller_role_name               = "ebs-csi-driver-controller"
  ebs_csi_controller_role_policy_name_prefix = "ebs-csi-driver-policy"
  oidc_url                                   = aws_iam_openid_connect_provider.openid_connect.url
}

###############################################################################
############################### EKS CLUSTER ###################################
###############################################################################

module "eks" {
  source          = "terraform-aws-modules/eks/aws"
  cluster_name    = var.cluster_name
  cluster_version = "1.17"
  subnets         = module.vpc.private_subnets
  vpc_id          = module.vpc.vpc_id

  worker_groups = [
    {
      name          = "worker-group-1"
      instance_type = data.aws_ec2_instance_type_offering.ubuntu_micro.id
      subnets       = [module.vpc.private_subnets[0]]
      # additional_security_group_ids = [aws_security_group.worker_group_mgmt_one.id]
      asg_desired_capacity = 1
    },
    {
      name          = "worker-group-2"
      instance_type = data.aws_ec2_instance_type_offering.ubuntu_micro.id
      subnets       = [module.vpc.private_subnets[1]]
      # additional_security_group_ids = [aws_security_group.worker_group_mgmt_two.id]
      asg_desired_capacity = 1
    },
    {
      name          = "worker-group-3"
      instance_type = data.aws_ec2_instance_type_offering.ubuntu_micro.id
      subnets       = [module.vpc.private_subnets[2]]
      # additional_security_group_ids = [aws_security_group.worker_group_mgmt_two.id]
      asg_desired_capacity = 1
    }
  ]
}
provider "kubernetes" {
  host                   = data.aws_eks_cluster.cluster.endpoint
  token                  = data.aws_eks_cluster_auth.cluster.token
  cluster_ca_certificate = base64decode(data.aws_eks_cluster.cluster.certificate_authority.0.data)
  load_config_file       = false
}

###############################################################################
#################################### TODO #####################################
###############################################################################

# Add s3 bucket and vault

###############################################################################
################################# OUTPUTS #####################################
###############################################################################


output "cluster_id" {
  description = "EKS cluster ID."
  value       = module.eks.cluster_id
}

output "cluster_endpoint" {
  description = "Endpoint for EKS control plane."
  value       = module.eks.cluster_endpoint
}

output "config_map_aws_auth" {
  description = "A kubernetes configuration to authenticate to EKS cluster."
  value       = module.eks.config_map_aws_auth
}
