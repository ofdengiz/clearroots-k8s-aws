output "master_public_ip" {
  value       = aws_instance.master.public_ip
  description = "Master node public IP"
}

output "master_private_ip" {
  value       = aws_instance.master.private_ip
  description = "Master node private IP"
}

output "worker_public_ip" {
  value       = aws_eip.worker.public_ip
  description = "Worker node Elastic IP"
}

output "website_url" {
  value       = "https://${var.domain_name}"
  description = "HTTPS website URL"
}

output "ssh_master" {
  value       = "ssh -i ${var.key_name}.pem ubuntu@${aws_instance.master.public_ip}"
  description = "Master SSH command"
}

output "ssh_worker" {
  value       = "ssh -i ${var.key_name}.pem ubuntu@${aws_eip.worker.public_ip}"
  description = "Worker SSH command"
}
