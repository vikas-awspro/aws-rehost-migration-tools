output "vpc_id"             { value = aws_vpc.this.id }
output "vpc_cidr"           { value = aws_vpc.this.cidr_block }
output "public_subnet_ids"  { value = [for s in aws_subnet.public  : s.id] }
output "private_subnet_ids" { value = [for s in aws_subnet.private : s.id] }

output "mgn_staging_sg_id"       { value = aws_security_group.mgn_staging.id }
output "dms_sg_id"               { value = aws_security_group.dms.id }
output "datasync_endpoint_sg_id" { value = aws_security_group.datasync_endpoint.id }
