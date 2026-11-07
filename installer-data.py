import json, sys

name, recovery_size, root_size, volume_id = sys.argv[1], int(sys.argv[2]), int(sys.argv[3]), sys.argv[4]

print(json.dumps({
    "os_list": [
        {
            "name": "Bande Linux (Mac mini M2)",
            "default_os_name": "Bande Linux",
            "boot_object": "unboot.bin",
            "next_object": "unboot/boot.bin",
            "package": f"{name}.zip",
            "supported_fw": ["13.5"],
            "partitions": [
                {
                    "name": "EFI",
                    "type": "EFI",
                    "size": "1GB",
                    "format": "fat",
                    "volume_id": volume_id,
                    "copy_firmware": True,
                    "copy_installer_data": True,
                    "source": "esp",
                },
                {
                    "name": "BANDE-RECOVERY",
                    "type": "Linux",
                    "size": "6GB",
                    "image": "recovery.img",
                    "recovery": True,
                },
                {
                    "name": "BANDE-ROOT",
                    "type": "Linux",
                    "size": f"{root_size}B",
                    "expand": True,
                    "image": "root.img",
                },
            ],
        }
    ]
}, indent=4))
