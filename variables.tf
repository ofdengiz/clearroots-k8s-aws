variable "region" {
  description = "AWS Region"
  default     = "us-east-1"
}

variable "project_name" {
  description = "Project name used in tags"
  default     = "clearroots"
}

variable "ami" {
  description = "Ubuntu 22.04 AMI for us-east-1"
  default     = "ami-0c7217cdde317cfec"
}

variable "instance_type" {
  description = "EC2 instance type"
  default     = "t3.micro"
}

variable "key_name" {
  description = "Existing AWS key pair name"
  default     = "clearroots-key"
}

variable "domain_name" {
  description = "Public subdomain for the website"
  default     = "clearroots.omerdengiz.com"
}

variable "hosted_zone_id" {
  # No default: this is account-specific. Supply it at apply time, e.g.
  #   terraform apply -var="hosted_zone_id=Z0123456789ABCDEFGHIJ"
  description = "Route 53 hosted zone ID that owns the parent domain"
  type        = string
}

variable "container_image" {
  description = "Public container image URI for the ClearRoots website"
  default     = "docker.io/ofdengiz/clearroots-web:latest"
}
