import asyncio
import warnings
warnings.filterwarnings('ignore')

from pymobiledevice3.lockdown import create_using_usbmux
from pymobiledevice3.services.afc import AfcService

APP = '/private/var/containers/Bundle/Application/FE790E55-F36B-46F7-86FC-29F388D12830/AIKeyboard.app'


def names(items):
    out = []
    for it in items:
        if isinstance(it, str):
            out.append(it)
        elif isinstance(it, dict):
            out.append(it.get('name') or (list(it.keys())[0] if it else '?'))
        else:
            out.append(str(it))
    return out


async def ls(afc, p, label, indent='  '):
    print('== %s ==' % label)
    try:
        items = await afc.listdir(p)
        for n in sorted(names(items)):
            print(indent + n)
    except Exception as e:
        print(indent + 'ERR ' + repr(e))
    print()


async def main():
    ld = await create_using_usbmux(serial=None)
    afc = AfcService(lockdown=ld)
    await ls(afc, APP, 'app 根')
    await ls(afc, APP + '/dict', 'app/dict')
    await ls(afc, APP + '/PlugIns', 'PlugIns')
    await ls(afc, APP + '/PlugIns/AIKeyboardExtension.appex', 'appex 根')
    await ls(afc, APP + '/PlugIns/AIKeyboardExtension.appex/dict', 'appex/dict')


asyncio.run(main())
