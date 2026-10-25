"""核验设备上墨语的版本号与签名状态。"""
import asyncio
import sys

from pymobiledevice3.lockdown import create_using_usbmux
from pymobiledevice3.services.installation_proxy import InstallationProxyService

TARGET = 'com.example.moyu'


async def main():
    ld = await create_using_usbmux(serial=None)
    svc = InstallationProxyService(lockdown=ld)
    apps = await svc.get_apps(application_type='Any')
    hits = []
    for bid, info in apps.items():
        if bid.startswith(TARGET):
            hits.append(info)
            print('BUNDLE   :', bid)
            print('  name   :', info.get('CFBundleDisplayName') or info.get('CFBundleName'))
            print('  version:', info.get('CFBundleShortVersionString'))
            print('  build  :', info.get('CFBundleVersion'))
            print('  signer :', info.get('SignerIdentity'))
            print('  valid  :', info.get('ProfileValidated'))
    if not hits:
        print('NOT_INSTALLED')
        return 1
    print()
    print('TOTAL_APPS:', len(apps))
    return 0


sys.exit(asyncio.run(main()))
