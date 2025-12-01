# ==============================
# 1. Terraform 版本与 Provider 约束（保持你的原配置）
# ==============================
terraform {
  required_providers {
    alicloud = {
      source  = "aliyun/alicloud"
      version = ">= 1.200.0"
    }
  }
}

# ==============================
# 2. 阿里云 Provider 配置
# ==============================
provider "alicloud" {
  region = "cn-beijing"  # 与已有资源同地域
  # access_key = "你的AK"（按需配置）
  # secret_key = "你的SK"（按需配置）
}

# ==============================
# 3. 自动查询已有资源（不变，确保能查到 VPC/子网/ECS/安全组）
# ==============================
# 3.1 查询已有 VPC（替换为你的 VPC 名称）
data "alicloud_vpcs" "existing" {
  name_regex = "test-vpc"
}

# 3.2 查询已有子网（属于上述 VPC + 标签过滤）
data "alicloud_vswitches" "existing" {
  vpc_id = data.alicloud_vpcs.existing.ids[0]
  tags = {
    Env = "test"  # 无标签可删除此块
  }
  count = length(data.alicloud_vpcs.existing.ids) > 0 ? 1 : 0
}

# 3.3 查询已有 ECS（属于上述 VPC + 标签过滤）
data "alicloud_instances" "existing" {
  vpc_id = data.alicloud_vpcs.existing.ids[0]
  tags = {
    Env = "test"  # 无标签可删除此块
  }
  count = length(data.alicloud_vpcs.existing.ids) > 0 ? 1 : 0
}

# 3.4 查询已有安全组（替换为你的安全组名称）
data "alicloud_security_groups" "existing" {
  vpc_id     = data.alicloud_vpcs.existing.ids[0]
  name_regex = "test-sg"
}

# ==============================
# 4. 公网 ALB 实例（核心修复：适配旧版参数）
# ==============================
resource "alicloud_alb_load_balancer" "public_alb" {
  # 基本信息
  load_balancer_name = "public-alb-test"
  vpc_id             = data.alicloud_vpcs.existing.ids[0]
  address_type       = "Internet"  # 公网类型
  load_balancer_edition = "Standard"  # 必填：ALB 标准版（旧版必填参数）

  # 计费配置（旧版要求块结构，包含公网计费模式）
  load_balancer_billing_config {
    pay_type           = "PayAsYouGo"  # 按量付费
    internet_charge_type = "PayByTraffic"  # 按流量计费（原参数移到此处）
  }

  # 可用区与子网绑定（旧版要求块结构，而非列表）
  # 循环创建两个可用区的绑定（与子网数量匹配）
  dynamic "zone_mapping" {
    for_each = data.alicloud_vswitches.existing[0].switches
    content {
      zone_id    = zone_mapping.value.zone_id
      vswitch_id = zone_mapping.value.id
    }
  }

  tags = {
    Name = "public-alb-test"
    Env  = "test"
  }
}

# ==============================
# 5. ALB 监听（80 端口 HTTP）
# ==============================
resource "alicloud_alb_listener" "http_80" {
  load_balancer_id = alicloud_alb_load_balancer.public_alb.id
  listener_name    = "http-80-public"
  port             = 80
  protocol         = "HTTP"

  # 前端配置
  frontend_config {
    protocol = "HTTP"
    port     = 80
  }

  # 默认转发到目标组（旧版目标组资源名变更）
  default_actions {
    type             = "ForwardGroup"
    forward_group_id = alicloud_alb_target_group.ecs_target.id  # 关联旧版目标组
  }

  # 健康检查（不变）
  health_check_config {
    enabled             = true
    protocol            = "HTTP"
    port                = 80
    path                = "/"
    healthy_threshold   = 3
    unhealthy_threshold = 3
    timeout             = 3
    interval            = 5
    healthy_http_codes  = "200-299"
  }

  # 会话保持（不变）
  session_sticky_config {
    enabled = false
  }
}

# ==============================
# 6. ALB 目标组（修复：旧版资源类型）
# ==============================
resource "alicloud_alb_target_group" "ecs_target" {  # 旧版资源名：alicloud_alb_target_group
  target_group_name = "ecs-target-group-public"
  load_balancer_id  = alicloud_alb_load_balancer.public_alb.id
  target_type       = "Instance"  # 目标类型：ECS
  scheduler         = "RoundRobin"  # 轮询算法
}

# ==============================
# 7. 绑定 ECS 到目标组（修复：旧版资源类型）
# ==============================
resource "alicloud_alb_target_attachment" "ecs_attach" {  # 旧版资源名：alicloud_alb_target_attachment
  count             = length(data.alicloud_instances.existing[0].instances)
  target_group_id   = alicloud_alb_target_group.ecs_target.id
  target_id         = data.alicloud_instances.existing[0].instances[count.index].id
  port              = 80  # Nginx 端口
  weight            = 100
  zone_id           = data.alicloud_instances.existing[0].instances[count.index].zone_id
}

# ==============================
# 8. 安全组规则（确保 ALB 能访问 ECS 80 端口）
# ==============================
resource "alicloud_security_group_rule" "allow_alb_http" {
  type              = "ingress"
  ip_protocol       = "tcp"
  nic_type          = "intranet"
  policy            = "accept"
  port_range        = "80/80"
  priority          = 5
  security_group_id = data.alicloud_security_groups.existing.ids[0]
  cidr_ip           = "0.0.0.0/0"
}

# ==============================
# 9. 输出访问信息
# ==============================
output "public_alb_info" {
  value = {
    alb_id           = alicloud_alb_load_balancer.public_alb.id
    alb_name         = alicloud_alb_load_balancer.public_alb.load_balancer_name
    public_ip        = alicloud_alb_load_balancer.public_alb.address  # 公网 IP
    access_url       = "http://${alicloud_alb_load_balancer.public_alb.address}:80"  # 公网访问地址
    listener_port    = alicloud_alb_listener.http_80.port
    bound_ecs_ids    = [for ecs in data.alicloud_instances.existing[0].instances : ecs.id]
  }
  description = "公网 ALB 配置信息"
}
