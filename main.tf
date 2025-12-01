# ==============================
# 1. Terraform 版本与 Provider 约束
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
# 3. 自动查询已有资源（适配低版本数据源语法）
# ==============================
# 3.1 查询已有 VPC（替换为你的 VPC 名称）
data "alicloud_vpcs" "existing" {
  name_regex = "test-vpc"
}

# 3.2 查询已有子网（属于上述 VPC，低版本用 vswitches 而非 switches）
data "alicloud_vswitches" "existing" {
  vpc_id = data.alicloud_vpcs.existing.ids[0]
  tags = {
    Env = "test"  # 无标签可删除此块
  }
  count = length(data.alicloud_vpcs.existing.ids) > 0 ? 1 : 0
}

# 3.3 查询已有 ECS（属于上述 VPC，低版本用 instances 列表）
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
# 4. 公网 CLB 实例（低版本兼容，替代 ALB）
# ==============================
resource "alicloud_slb_load_balancer" "public_clb" {
  # 基本信息
  load_balancer_name = "public-clb-test"
  vpc_id             = data.alicloud_vpcs.existing.ids[0]
  address_type       = "internet"  # 公网类型
  internet_charge_type = "paybytraffic"  # 按流量计费
  internet_bandwidth = 5  # 公网带宽 5Mbps

  # 绑定双子网（跨可用区高可用，低版本直接用 vswitch_ids）
  vswitch_ids = [
    for vswitch in data.alicloud_vswitches.existing[0].vswitches : vswitch.id
  ]

  tags = {
    Name = "public-clb-test"
    Env  = "test"
  }
}

# ==============================
# 5. CLB 监听（80 端口 HTTP 协议）
# ==============================
resource "alicloud_slb_listener" "http_80" {
  load_balancer_id = alicloud_slb_load_balancer.public_clb.id
  port             = 80
  protocol         = "http"
  backend_port     = 80  # 转发到 ECS 的 80 端口（Nginx）
  scheduler        = "round_robin"  # 轮询算法

  # 健康检查（检测 ECS 上的 Nginx）
  health_check {
    enabled             = true
    type                = "http"
    uri                 = "/"  # 检查 Nginx 首页
    healthy_http_status = "http_2xx"  # 200-299 视为健康
    interval            = 5  # 检查间隔 5 秒
    timeout             = 3  # 超时 3 秒
    healthy_threshold   = 3  # 3 次成功视为健康
    unhealthy_threshold = 3  # 3 次失败视为不健康
  }

  # 会话保持（测试环境关闭）
  sticky_session = "off"
}

# ==============================
# 6. 绑定 ECS 到 CLB 后端服务器组
# ==============================
resource "alicloud_slb_backend_server" "ecs_attach" {
  count             = length(data.alicloud_instances.existing[0].instances)
  load_balancer_id  = alicloud_slb_load_balancer.public_clb.id
  backend_server_id = data.alicloud_instances.existing[0].instances[count.index].id
  weight            = 100  # 权重相同
  type              = "ecs"  # 目标类型：ECS 实例
}

# ==============================
# 7. 安全组规则（放行公网 80 端口访问 CLB）
# ==============================
resource "alicloud_security_group_rule" "allow_public_http" {
  type              = "ingress"
  ip_protocol       = "tcp"
  nic_type          = "internet"  # 公网访问
  policy            = "accept"
  port_range        = "80/80"
  priority          = 4
  security_group_id = data.alicloud_security_groups.existing.ids[0]
  cidr_ip           = "0.0.0.0/0"  # 允许所有公网 IP 访问
}

# ==============================
# 8. 输出公网访问信息
# ==============================
output "public_clb_info" {
  value = {
    clb_id           = alicloud_slb_load_balancer.public_clb.id
    clb_name         = alicloud_slb_load_balancer.public_clb.load_balancer_name
    public_ip        = alicloud_slb_load_balancer.public_clb.address  # 公网 IP
    access_url       = "http://${alicloud_slb_load_balancer.public_clb.address}:80"  # 公网访问地址
    listener_port    = alicloud_slb_listener.http_80.port
    bound_ecs_ids    = [for ecs in data.alicloud_instances.existing[0].instances : ecs.id]
    bandwidth        = alicloud_slb_load_balancer.public_clb.internet_bandwidth
  }
  description = "公网 CLB 配置信息及访问地址"
}
