resource "aws_route53_record" "clearroots_web" {
  zone_id = var.hosted_zone_id
  name    = var.domain_name
  type    = "A"
  ttl     = 300

  records = [aws_eip.worker.public_ip]
}
