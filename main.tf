# ==============================
# 1. Terraform 版本与 Provider 约束
# ==============================
terraform {
  required_providers {
    alicloud = {
      source  = "aliyun/alicloud"
      version = ">= 1.200.0"  # 按你的实际版本保留，无需修改
    }
  }
}

# ==============================
# 2. 阿里云 Provider 配置
# ==============================
provider "alicloud" {
  region = "cn-beijing"  # 与已有资源同地域
  # access_key = "你的AK"（必填，无环境变量则取消注释填写）
  # secret_key = "你的SK"（必填，无环境变量则取消注释填写）
}

# ==============================
# 3. 手动指定已有资源 ID（唯一可靠方式）
# ==============================
variable "ecs_ids" {
  type        = list(string)
  default     = ["i-xxxxxxxxxxxxxxxxx", "i-xxxxxxxxxxxxxxxxx"]  # 替换为你的两台 ECS ID
  description = "已有两台 ECS 的实例 ID"
}

variable "security_group_id" {
  type        = string
  default     = "sg-xxxxxxxxxxxxxxxxx"  # 替换为你的 ECS 安全组 ID
  description = "已有 ECS 绑定的安全组 ID"
}

# ==============================
# 4. 公网 CLB 实例（仅保留 2 个必填参数）
# ==============================
resource "alicloud_slb_load_balancer" "public_clb" {
  load_balancer_name = "public-clb-test"
  address_type       = "internet"  # 公网类型（唯一必填参数）
}

# ==============================
# 5. CLB 监听（仅保留 5 个核心必填参数，无健康检查复杂配置）
# ==============================
resource "alicloud_slb_listener" "http_80" {
  load_balancer_id = alicloud_slb_load_balancer.public_clb.id
  frontend_port    = 80  # 早期版本唯一支持的监听端口参数
  protocol         = "http"
  backend_port     = 80  # 转发到 ECS 80 端口（Nginx）
  scheduler        = "round_robin"  # 轮询算法（必填）
  # 移除所有健康检查相关参数（早期版本默认开启基础健康检查）
}

# ==============================
# 6. 绑定 ECS 到 CLB（用单数资源循环绑定，早期版本必支持）
# ==============================
resource "alicloud_slb_backend_server" "ecs_attach_0" {  # 第一台 ECS
  load_balancer_id  = alicloud_slb_load_balancer.public_clb.id
  backend_server_id = var.ecs_ids[0]  # 第一台 ECS ID
}

resource "alicloud_slb_backend_server" "ecs_attach_1" {  # 第二台 ECS
  load_balancer_id  = alicloud_slb_load_balancer.public_clb.id
  backend_server_id = var.ecs_ids[1]  # 第二台 ECS ID
}

# ==============================
# 7. 安全组规则（放行公网+内网 80 端口，确保访问通畅）
# ==============================
resource "alicloud_security_group_rule" "allow_public_http" {
  type              = "ingress"
  ip_protocol       = "tcp"
  nic_type          = "internet"
  policy            = "accept"
  port_range        = "80/80"
  priority          = 4
  security_group_id = var.security_group_id
  cidr_ip           = "0.0.0.0/0"
}

resource "alicloud_security_group_rule" "allow_intranet_http" {
  type              = "ingress"
  ip_protocol       = "tcp"
  nic_type          = "intranet"
  policy            = "accept"
  port_range        = "80/80"
  priority          = 5
  security_group_id = var.security_group_id
  cidr_ip           = "0.0.0.0/0"
}

# ==============================
# 8. 输出公网访问信息
# ==============================
output "public_clb_info" {
  value = {
    clb_id           = alicloud_slb_load_balancer.public_clb.id
    clb_name         = alicloud_slb_load_balancer.public_clb.load_balancer_name
    public_ip        = alicloud_slb_load_balancer.public_clb.address  # 公网访问 IP
    access_url       = "http://${alicloud_slb_load_balancer.public_clb.address}:80"  # 直接访问
    bound_ecs_ids    = var.ecs_ids
  }
  description = "公网 CLB 配置信息"
}
