output "jenkins_instance_id"        { value = aws_instance.jenkins.id }
output "jenkins_public_ip"          { value = aws_instance.jenkins.public_ip }
output "jenkins_private_ip"         { value = aws_instance.jenkins.private_ip }
output "jenkins_alb_dns"            { value = aws_lb.jenkins.dns_name }
output "jenkins_security_group_id"  { value = aws_security_group.jenkins.id }
output "jenkins_role_arn"           { value = aws_iam_role.jenkins.arn }
output "jenkins_ebs_volume_id"      { value = aws_ebs_volume.jenkins_home.id }
output "sonarqube_url"              { value = "http://${aws_instance.jenkins.public_ip}:9000" }
