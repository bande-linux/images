import json, sys

name, root_size, volume_id = sys.argv[1], int(sys.argv[2]), sys.argv[3]

print(json.dumps({
    "os_list": [
        {
            "name": "Debian 13 server (Mac mini M2, J473)",
            "default_os_name": "Unbound Linux",
            "boot_object": "unboot.bin",
            "next_object": "unboot/boot.bin",
            "package": f"{name}.zip",
            "supported_fw": ["13.5"],
            "partitions": [
                {
                    "name": "EFI",
                    "type": "EFI",
                    "size": "512MB",
                    "format": "fat",
                    "volume_id": volume_id,
                    "copy_firmware": True,
                    "copy_installer_data": True,
                    "source": "esp",
                },
                {
                    "name": "Root",
                    "type": "Linux",
                    "size": f"{root_size}B",
                    "expand": True,
                    "image": "root.img",
                },
            ],
        }
    ]
}, indent=4))
