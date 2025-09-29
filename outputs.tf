output "public_ip" {
  description = "Public IP address of the dev server"
  value       = aws_instance.dev_server.public_ip
}
