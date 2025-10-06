output "public_ip" {
  description = "Public IP address of the dev server"
  value       = aws_instance.dev_server.public_ip
}

output "jenkins_url" {
  description = "URL to access Jenkins UI"
  value       = "http://${aws_instance.dev_server.public_ip}:8080"
}

output "sonarqube_url" {
  description = "URL to access SonarQube UI"
  value       = "http://${aws_instance.dev_server.public_ip}:9000"
}

output "k3s_master_node" {
  description = "K3s master node internal IP"
  value       = aws_instance.dev_server.private_ip
}
