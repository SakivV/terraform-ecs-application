# # IAM Role
resource "aws_iam_role" "ecsTaskExecutionRole" {
  name               = "${var.app_name}-execution-task-role"
  assume_role_policy = data.aws_iam_policy_document.assume_role_policy.json
  tags = {
    Name        = "${var.app_name}-ecs-iam-role"
  }
}

#Get value of VPC ID
data "aws_ssm_parameter" "vpcid" {
  name = "/cloudmagic/vpc/id"
}
#Get values of Subnets
data "aws_ssm_parameter" "public_subnets" {
  name = "/cloudmagic/public/subnet/ids"
}

data "aws_ssm_parameter" "private_subnets" {
  name = "/cloudmagic/private/subnet/ids"
}

locals {
  public_subnets_ids = split(",", data.aws_ssm_parameter.public_subnets.value)
  private_subnets_ids = split(",", data.aws_ssm_parameter.private_subnets.value)
}

data "aws_iam_policy_document" "assume_role_policy" {
  statement {
    actions = ["sts:AssumeRole"]

    principals {
      type        = "Service"
      identifiers = ["ecs-tasks.amazonaws.com"]
    }
  }
}

resource "aws_iam_role_policy_attachment" "ecsTaskExecutionRole_policy" {
  role       = aws_iam_role.ecsTaskExecutionRole.name
  policy_arn = "arn:aws:iam::aws:policy/service-role/AmazonEC2ContainerServiceforEC2Role"
}

# CloudWatch Log group
resource "aws_cloudwatch_log_group" "log-group" {
  name = "${var.app_name}-logs"
  tags = {
    Application = var.app_name
  }
}

resource "aws_ecs_cluster" "aws-ecs-cluster" {
  name = var.app_name
  tags = {
    Name        = var.app_name
  }
}

# Task Defination
resource "aws_ecs_task_definition" "aws-ecs-task" {
  family = "${var.app_name}-nginx-task"
  container_definitions = <<DEFINITION
  [
    {
      "name": "${var.app_name}-container",
      "image": "cloudmagicmaster/nginx:1.1",
      "essential": true,
      "logConfiguration": {
        "logDriver": "awslogs",
        "options": {
          "awslogs-group": "${aws_cloudwatch_log_group.log-group.id}",
          "awslogs-region": "${var.aws_region}",
          "awslogs-stream-prefix": "${var.app_name}"
        }
      },
      "portMappings": [
        {
          "containerPort": 80,
          "hostPort": 80
        }
      ],
      "cpu": 256,
      "memory": 512,
      "networkMode": "awsvpc"
    }
  ]
  DEFINITION

  requires_compatibilities = ["FARGATE"]
  network_mode             = "awsvpc"
  memory                   = "512"
  cpu                      = "256"
  execution_role_arn       = aws_iam_role.ecsTaskExecutionRole.arn
  task_role_arn            = aws_iam_role.ecsTaskExecutionRole.arn

  tags = {
    Name        = "${var.app_name}-td"
  }
}

data "aws_ecs_task_definition" "main" {
  task_definition = aws_ecs_task_definition.aws-ecs-task.family
}

#Security Group
resource "aws_security_group" "service_security_group" {
  vpc_id = data.aws_ssm_parameter.vpcid.value
  ingress {
    from_port       = 80
    to_port         = 80
    protocol        = "tcp"
    security_groups = [aws_security_group.load_balancer_security_group.id]
  }

  egress {
    from_port        = 0
    to_port          = 0
    protocol         = "-1"
    cidr_blocks      = ["0.0.0.0/0"]
    ipv6_cidr_blocks = ["::/0"]
  }

  tags = {
    Name        = "${var.app_name}-service-sg"
  }
}

# Load Balancer Security group
resource "aws_security_group" "load_balancer_security_group" {
  vpc_id = data.aws_ssm_parameter.vpcid.value
  ingress {
    from_port        = 80
    to_port          = 80
    protocol         = "tcp"
    cidr_blocks      = ["0.0.0.0/0"]
    ipv6_cidr_blocks = ["::/0"]
  }

  egress {
    from_port        = 0
    to_port          = 0
    protocol         = "-1"
    cidr_blocks      = ["0.0.0.0/0"]
    ipv6_cidr_blocks = ["::/0"]
  }
  tags = {
    Name        = "${var.app_name}-sg"
  }
}

resource "aws_alb" "application_load_balancer" {
  name               = "${var.app_name}-alb"
  internal           = false
  load_balancer_type = "application"
  subnets            = [local.public_subnets_ids[0],local.public_subnets_ids[1]]
  security_groups    = [aws_security_group.load_balancer_security_group.id]

  tags = {
    Name        = "${var.app_name}-alb"
  }
}

resource "aws_lb_target_group" "target_group" {
  name        = "${var.app_name}-trg"
  port        = 80
  protocol    = "HTTP"
  target_type = "ip"
  vpc_id      = data.aws_ssm_parameter.vpcid.value

  # health_check {
  #   healthy_threshold   = "3"
  #   interval            = "300"
  #   protocol            = "HTTP"
  #   matcher             = "200"
  #   timeout             = "3"
  #   path                = "/v1/status"
  #   unhealthy_threshold = "2"
  # }

  tags = {
    Name        = "${var.app_name}-lb-tg"
  }
}

resource "aws_lb_listener" "listener" {
  load_balancer_arn = aws_alb.application_load_balancer.id
  port              = "80"
  protocol          = "HTTP"

  default_action {
    type             = "forward"
    target_group_arn = aws_lb_target_group.target_group.id
  }
}

# Task Service
resource "aws_ecs_service" "aws-ecs-service" {
  name                 = "${var.app_name}-service"
  cluster              = aws_ecs_cluster.aws-ecs-cluster.id
  task_definition      = "${aws_ecs_task_definition.aws-ecs-task.family}:${max(aws_ecs_task_definition.aws-ecs-task.revision, data.aws_ecs_task_definition.main.revision)}"
  launch_type          = "FARGATE"
  scheduling_strategy  = "REPLICA"
  desired_count        = 1
  force_new_deployment = true

  network_configuration {
    subnets          = [local.private_subnets_ids[0],local.private_subnets_ids[1]]
    assign_public_ip = true
    security_groups = [
      aws_security_group.service_security_group.id,
    #   aws_security_group.load_balancer_security_group.id
    ]
  }

  load_balancer {
    target_group_arn = aws_lb_target_group.target_group.arn
    container_name   = "${var.app_name}-container"
    container_port   = 80
  }

 depends_on = [aws_lb_listener.listener]
}