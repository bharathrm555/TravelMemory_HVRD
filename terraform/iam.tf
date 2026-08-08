# ---------------------------------------------------------------------------
# Part 1.4 - IAM roles for the EC2 instances
#
# An IAM role lets an EC2 instance call AWS APIs WITHOUT you ever putting
# access keys on the box. AWS injects short-lived, auto-rotating credentials
# into the instance metadata instead. That is the secure pattern.
# ---------------------------------------------------------------------------

# The trust policy: "the EC2 service is allowed to assume this role".
data "aws_iam_policy_document" "ec2_assume_role" {
  statement {
    effect  = "Allow"
    actions = ["sts:AssumeRole"]

    principals {
      type        = "Service"
      identifiers = ["ec2.amazonaws.com"]
    }
  }
}

resource "aws_iam_role" "ec2" {
  name               = "${var.project_name}-ec2-role"
  description        = "Role for TravelMemory EC2 instances (SSM + CloudWatch)"
  assume_role_policy = data.aws_iam_policy_document.ec2_assume_role.json

  tags = {
    Name = "${var.project_name}-ec2-role"
  }
}

# Lets you open a shell on either instance from the AWS Console via Session
# Manager - very handy for the PRIVATE database box, which has no public IP.
resource "aws_iam_role_policy_attachment" "ssm" {
  role       = aws_iam_role.ec2.name
  policy_arn = "arn:aws:iam::aws:policy/AmazonSSMManagedInstanceCore"
}

# Lets the instances ship logs and metrics to CloudWatch.
resource "aws_iam_role_policy_attachment" "cloudwatch" {
  role       = aws_iam_role.ec2.name
  policy_arn = "arn:aws:iam::aws:policy/CloudWatchAgentServerPolicy"
}

# An instance profile is the wrapper that actually attaches a role to an EC2.
resource "aws_iam_instance_profile" "ec2" {
  name = "${var.project_name}-ec2-profile"
  role = aws_iam_role.ec2.name
}
