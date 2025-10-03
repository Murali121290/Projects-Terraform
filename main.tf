terraform {
  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.0"
    }
  }
  required_version = ">= 1.3.0"
}

provider "aws" {
  region = "us-east-1"
}

# Lookup default VPC
data "aws_vpc" "default" {
  default = true
}

# Security Group
resource "aws_security_group" "ec2_sg" {
  name        = "dev_server_sg1"
  description = "Allow SSH, HTTP, Jenkins, and SonarQube"
  vpc_id      = data.aws_vpc.default.id

  # SSH
  ingress {
    from_port   = 22
    to_port     = 22
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }

  # HTTP
  ingress {
    from_port   = 80
    to_port     = 80
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }

  # Jenkins
  ingress {
    from_port   = 8080
    to_port     = 8080
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }

  # SonarQube
  ingress {
    from_port   = 9000
    to_port     = 9000
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }

  # Flask
  ingress {
    from_port   = 5000
    to_port     = 5000
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }

  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = {
    Name = "dev-server-sg"
  }
}

# EC2 instance
resource "aws_instance" "dev_server" {
  ami           = "ami-0fc5d935ebf8bc3bc" # Ubuntu 22.04 us-east-1
  instance_type = "t2.medium"
  key_name      = var.key_name
  vpc_security_group_ids = [aws_security_group.ec2_sg.id]

  user_data = file("${path.module}/userdata.sh")

  root_block_device {
    volume_size = 50       # 👈 Increase root volume size (GB)
    volume_type = "gp3"    # General Purpose SSD (recommended)
    delete_on_termination = true
  
  user_data = file("${path.module}/userdata.sh")

  tags = {
    Name        = "Dev-Server-Jenkins-SonarQube-Minikube"
    Environment = "Dev"
  }
}



