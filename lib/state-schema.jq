# A state file is exactly one document with one supported schema/transport.
def fields($expected): type == "object" and (keys == ($expected | sort));
def boundedint($min; $max): type == "number" and floor == . and . >= $min and . <= $max;
def name: type == "string" and test("^[A-Za-z0-9_-]{1,32}$");
def key: type == "string" and test("^[A-Za-z0-9_-]{43}$");
def sha256: type == "string" and test("^[a-f0-9]{64}$");
def kitversion: type == "string" and test("^(0|[1-9][0-9]*)\\.(0|[1-9][0-9]*)\\.(0|[1-9][0-9]*)$");
def coreversion: type == "string" and test("^v[0-9]+\\.[0-9]+\\.[0-9]+$");
def client:
    fields(["name","uuid","shortId"])
    and (.name | name)
    and (.uuid | type == "string" and test("^[a-f0-9]{8}-[a-f0-9]{4}-[a-f0-9]{4}-[a-f0-9]{4}-[a-f0-9]{12}$"))
    and (.shortId | type == "string" and test("^[a-f0-9]{16}$"));
length == 1 and (.[0] |
    fields(["schemaVersion","generation","transport","endpoint","port","target","serverName","privateKey","publicKey","clients","installed","lastSuccessfulSnapshot"])
    and .schemaVersion == 1 and .transport == "reality-tcp"
    and (.generation | boundedint(0; 9007199254740990))
    and (.endpoint | type == "string") and (.port | boundedint(1; 65535))
    and (.serverName | type == "string") and (.target | type == "string")
    and (.privateKey | key) and (.publicKey | key)
    and (.clients | type == "array" and all(.[]; client)
        and (map(.name) | length == (unique | length))
        and (map(.uuid) | length == (unique | length))
        and (map(.shortId) | length == (unique | length)))
    and (.installed | fields(["kitVersion","coreVersion","bundleId","contentSha256"])
        and (.kitVersion | kitversion) and (.coreVersion | coreversion)
        and (.contentSha256 | sha256)
        and (.bundleId == (.kitVersion + "-" + .coreVersion + "-" + .contentSha256)))
    and (.lastSuccessfulSnapshot == null or (.lastSuccessfulSnapshot | type == "string" and test("^snapshot-[0-9]+-[a-f0-9]{16}$")))
)
