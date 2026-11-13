resource "verda_ssh_key" "main" {
  name       = var.ssh_key_name
  public_key = trimspace(file(pathexpand(var.ssh_public_key_path)))
}

resource "verda_startup_script" "init" {
  name   = "obs-demo-init"
  script = file("${path.module}/../bootstrap.sh")
}


resource "verda_instance" "obs-demo" {
  hostname      = "obs-demo"
  description   = "VM for the observability assignment"
  instance_type = "CPU-TURIN.4V.16G"
  image         = "ubuntu-24.04"
  location      = "FIN-03"

  ssh_key_ids = [verda_ssh_key.main.id]
  
  os_volume = {
    name = "obs-demo-os"
    size = 200
    type = "NVMe"
  }


  startup_script_id = verda_startup_script.init.id
}

output "instance_id" {
  value = verda_instance.obs-demo.id
}

output "public_ip" {
  value = verda_instance.obs-demo.ip
}