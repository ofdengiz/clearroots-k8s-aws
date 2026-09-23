terraform {
  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.0"
    }
  }

  # Terraform state bucket is created manually outside Terraform.
  # Use a local backend.hcl file, for example:
  # bucket = "your-tf-state-bucket"
  # key    = "clearroots/k8s/terraform.tfstate"
  # region = "us-east-1"
  # Then run:
  # terraform init -backend-config=backend.hcl
  backend "s3" {}
}

provider "aws" {
  region = var.region
}

data "aws_caller_identity" "current" {}
data "aws_region" "current" {}

resource "aws_instance" "master" {
  ami                  = var.ami
  instance_type        = var.instance_type
  key_name             = var.key_name
  iam_instance_profile = aws_iam_instance_profile.ec2connectprofile.name
  user_data = templatefile("master.sh", {
    container_image = var.container_image
  })
  vpc_security_group_ids = [aws_security_group.k8s_sec_gr.id]

  tags = {
    Name    = "${var.project_name}-kube-master"
    Project = var.project_name
  }
}

resource "aws_instance" "worker" {
  ami                    = var.ami
  instance_type          = var.instance_type
  key_name               = var.key_name
  iam_instance_profile   = aws_iam_instance_profile.ec2connectprofile.name
  vpc_security_group_ids = [aws_security_group.k8s_sec_gr.id]

  user_data = templatefile("worker.sh", {
    region         = data.aws_region.current.name
    master_id      = aws_instance.master.id
    master_private = aws_instance.master.private_ip
    domain_name    = var.domain_name
  })

  tags = {
    Name    = "${var.project_name}-kube-worker"
    Project = var.project_name
  }

  depends_on = [aws_instance.master]
}

resource "aws_eip" "worker" {
  domain = "vpc"

  tags = {
    Name    = "${var.project_name}-worker-eip"
    Project = var.project_name
  }
}

resource "aws_eip_association" "worker" {
  instance_id   = aws_instance.worker.id
  allocation_id = aws_eip.worker.id
}

resource "aws_iam_instance_profile" "ec2connectprofile" {
  name = "ec2connectprofile-${var.project_name}"
  role = aws_iam_role.ec2connectcli.name
}

resource "aws_iam_role" "ec2connectcli" {
  name = "ec2connectcli-${var.project_name}"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Action    = "sts:AssumeRole"
      Effect    = "Allow"
      Principal = { Service = "ec2.amazonaws.com" }
    }]
  })
}

resource "aws_iam_role_policy" "ec2connect_inline" {
  name = "ec2connect-inline"
  role = aws_iam_role.ec2connectcli.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect   = "Allow"
        Action   = "ec2-instance-connect:SendSSHPublicKey"
        Resource = "arn:aws:ec2:${data.aws_region.current.name}:${data.aws_caller_identity.current.account_id}:instance/*"
        Condition = {
          StringEquals = { "ec2:osuser" = "ubuntu" }
        }
      },
      {
        Effect   = "Allow"
        Action   = "ec2:DescribeInstances"
        Resource = "*"
      }
    ]
  })
}

resource "aws_security_group" "k8s_sec_gr" {
  name = "${var.project_name}-k8s-sec-gr"

  tags = {
    Name    = "${var.project_name}-k8s-sec-gr"
    Project = var.project_name
  }

  # Node-to-node communication
  ingress {
    from_port = 0
    to_port   = 0
    protocol  = "-1"
    self      = true
  }

  # SSH
  ingress {
    from_port   = 22
    to_port     = 22
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }

  # HTTP for initial access and ACME challenge
  ingress {
    from_port   = 80
    to_port     = 80
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }

  # HTTPS served by Caddy on the worker
  ingress {
    from_port   = 443
    to_port     = 443
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }

  # Kubernetes API
  ingress {
    from_port   = 6443
    to_port     = 6443
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }

  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }
}
