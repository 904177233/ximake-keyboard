"""用 pyicloud 验证 Apple ID 账号密码是否仍然有效（走 SRP，与 GSA 不同路径）。"""
import sys

from pyicloud import PyiCloudService
from pyicloud.exceptions import PyiCloudFailedLoginException

APPLE_ID = 'z904177233@icloud.com'
PASSWORD = 'Zjcisme123@'

try:
    api = PyiCloudService(APPLE_ID, PASSWORD)
except PyiCloudFailedLoginException as exc:
    print('LOGIN_FAILED:', exc)
    sys.exit(2)
except Exception as exc:  # noqa: BLE001
    print('OTHER_ERROR:', type(exc).__name__, exc)
    sys.exit(3)

print('AUTH_OK requires_2fa =', api.requires_2fa)
if api.requires_2fa:
    print('=> 密码正确，账号开启双重认证')
else:
    print('=> 密码正确，未开启 2FA（或已信任）')
