locals {
  name_prefix = "${var.project}-${var.environment}"
  src_dir     = "${path.root}/../src"
  config_dir  = "${path.root}/../config"
}
