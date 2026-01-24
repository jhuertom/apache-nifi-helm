import uuid
import hashlib

def nifi_uuid(identity):
    # Java's UUID.nameUUIDFromBytes(identity.getBytes(StandardCharsets.UTF_8))
    # uses MD5 and sets version bits to 3.
    # Python's uuid.UUID(bytes=...) with manual bit manipulation:
    md5_hash = hashlib.md5(identity.encode('utf-8')).digest()
    
    # Set version to 3 (0x30) and variant to RFC 4122 (0x80)
    # This is exactly what Java's nameUUIDFromBytes does.
    uid_list = list(md5_hash)
    uid_list[6] = (uid_list[6] & 0x0f) | 0x30
    uid_list[8] = (uid_list[8] & 0x3f) | 0x80
    return str(uuid.UUID(bytes=bytes(uid_list)))

# Expected values for matching NiFi:
identities = ["nifiadmin", "CN=nifi-0.nifi.nifi", "CN=nifi.nifi"]
for id_str in identities:
    print(f"{id_str} -> {nifi_uuid(id_str)}")
