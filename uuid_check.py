import hashlib
import uuid

def calc_nifi_uuid(name):
    # NiFi implementation of UUID.nameUUIDFromBytes
    md5 = hashlib.md5(name.encode('utf-8')).digest()
    md5_bytes = bytearray(md5)
    md5_bytes[6] &= 0x0f
    md5_bytes[6] |= 0x30
    md5_bytes[8] &= 0x3f
    md5_bytes[8] |= 0x80
    return str(uuid.UUID(bytes=bytes(md5_bytes)))

print(f"nifiadmin: {calc_nifi_uuid('nifiadmin')}")
print(f"CN=nifiadmin,OU=people,DC=example,DC=com: {calc_nifi_uuid('CN=nifiadmin,OU=people,DC=example,DC=com')}")
print(f"CN=nifiadmin: {calc_nifi_uuid('CN=nifiadmin')}")
