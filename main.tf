provider "aws" { 
    region = "us-east-2"
}


resource "aws_launch_template" "example" {
  name_prefix   = "terraform-example-"
  image_id      = "ami-0d1b5a8c13042c939"
  instance_type = "t2.micro"

  user_data = base64encode(<<EOF
#!/bin/bash
mkdir -p /var/www
echo "Hello, World" > /var/www/index.html
nohup busybox httpd -f -p ${var.server_port} -h /var/www &
EOF
  )

  vpc_security_group_ids = [aws_security_group.instance.id]

  tag_specifications {
    resource_type = "instance"
    tags = {
      Name = "terraform-asg-example"
    }
  }
}

resource "aws_autoscaling_group" "example" {
  launch_template {
    id      = aws_launch_template.example.id
    version = "$Latest"
  }

  vpc_zone_identifier = data.aws_subnets.default.ids
  target_group_arns   = [aws_lb_target_group.asg.arn]
  health_check_type   = "ELB"
  min_size            = 2
  max_size            = 10

  tag {
    key                 = "Name"
    value               = "terraform-asg-example"
    propagate_at_launch = true
  }
}

resource "aws_security_group" "instance" { 
    name = "terraform-example-instance"
    ingress {
        from_port   = var.server_port
        to_port     = var.server_port
        protocol    = "tcp"
        cidr_blocks = ["0.0.0.0/0"]
    } 
}

variable "server_port" {
    description = "The port the server will use for HTTP requests" 
    type = number
    default = 8080
}

output "alb_dns_name" {
    value       = aws_lb.example.dns_name
    description = "The domain name of the load balancer"
}



data "aws_vpc" "default" { 
    default = true
}

data "aws_subnets" "default" {
    filter {
      name   = "vpc-id"
      values = [data.aws_vpc.default.id]
    }
}

# Creating the load balancer

resource "aws_lb" "example" {
    name                = "terraform-asg-example" 
    load_balancer_type  = "application"
    subnets             = data.aws_subnets.default.ids
    security_groups     = [aws_security_group.alb.id]
}

resource "aws_lb_listener" "http" { 
    load_balancer_arn = aws_lb.example.arn 
    port = 80
    protocol = "HTTP"
    
    # By default, return a simple 404 page
    default_action {
      type = "fixed-response"
      fixed_response {
        content_type = "text/plain"
        message_body = "404: page not found"
        status_code  = 404
      }       
    }
}

resource "aws_security_group" "alb" { 
    name = "terraform-example-alb"
    
    # Allow inbound HTTP requests
    ingress {
        from_port = 80
        to_port = 80
        protocol = "tcp"
        cidr_blocks = ["0.0.0.0/0"]
    }

    # Allow all outbound requests
    egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
    } 
}

# This target group will health check your Instances by periodically sending an
# HTTP request to each Instance and will consider the Instance “healthy” only if
# the Instance returns a response that matches the configured matcher 
# (e.g., you can configure a matcher to look for a 200 OK response). 
# If an Instance fails to respond, perhaps because that Instance has gone down 
# or is overloaded, it will be marked as “unhealthy,” and the target group will
# automatically stop sending traffic to it to minimize disruption for users.

resource "aws_lb_target_group" "asg" { 
    name = "terraform-asg-example" 
    port = var.server_port
    protocol = "HTTP"
    vpc_id   = data.aws_vpc.default.id

    health_check {
        path= "/"
        protocol= "HTTP"
        matcher= "200"
        interval= 15
        timeout= 3
        healthy_threshold= 2
        unhealthy_threshold = 2
    } 
}

# The preceding code adds a listener rule that sends requests that match any
# path to the target group that contains your ASG.

resource "aws_lb_listener_rule" "asg" { 
    listener_arn = aws_lb_listener.http.arn 
    priority = 100
    
    condition {
      path_pattern {
        values = ["*"]
      }
    }
    action {
      type             = "forward"
      target_group_arn = aws_lb_target_group.asg.arn
    } 
}
