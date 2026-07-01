param location string
param environmentName string
param containerAppName string
param image string
param logAnalyticsWorkspaceName string
param storageAccountName string
param dashboardDeliveryMode string

resource logAnalyticsWorkspace 'Microsoft.OperationalInsights/workspaces@2023-09-01' existing = {
  name: logAnalyticsWorkspaceName
}

var usesHostedAssets = contains([
  'Hosted'
  'Dual'
], dashboardDeliveryMode)
var storageDnsSuffix = environment().suffixes.storage
var dashboardBlobName = usesHostedAssets ? 'VulnerabilityDashboard.Hosted.html' : 'VulnerabilityDashboard.html'
var dashboardAssetsDirectoryName = usesHostedAssets ? 'VulnerabilityDashboard.Hosted.assets' : 'VulnerabilityDashboard.assets'
var hostedAssetRelativePaths = [
  'runtime/dashboard.css'
  'runtime/dashboard.js'
  'runtime/pako.js'
  'vendor/chart.js'
  'data/summary.json'
  'optional/pdf-export.runtime.js'
  'optional/pdf-export.bundle.js'
  'data/payload.json.gz'
]
var assetDownloadLines = [for assetRelativePath in hostedAssetRelativePaths: '    download_blob /data/${dashboardAssetsDirectoryName}/${assetRelativePath} "${dashboardAssetsDirectoryName}/${assetRelativePath}" || true']
var assetDownloadBlock = usesHostedAssets
  ? join(concat([
      '    mkdir -p "/data/${dashboardAssetsDirectoryName}"'
    ], assetDownloadLines), '\n')
  : ''
var startupScriptTemplate = '''
#!/bin/sh
SYNC_INTERVAL_SECONDS=60

get_token() {
    wget -qO- \
        --header "X-IDENTITY-HEADER: $IDENTITY_HEADER" \
        "${IDENTITY_ENDPOINT}?resource=https%3A%2F%2Fstorage.azure.com&api-version=2019-08-01" 2>/dev/null \
        | sed -n 's/.*"access_token":"\([^"]*\)".*/\1/p'
}

download_blob() {
    DEST_PATH="$1"
    BLOB_PATH="$2"
    TEMP_PATH="${DEST_PATH}.tmp"
    mkdir -p "$(dirname "$DEST_PATH")"
    if wget -qO "$TEMP_PATH" \
        --header "Authorization: Bearer $TOKEN" \
        --header "x-ms-version: 2020-10-02" \
        "https://__STORAGE_ACCOUNT_NAME__.blob.__STORAGE_DNS_SUFFIX__/dashboards/$BLOB_PATH" 2>/dev/null; then
        mv "$TEMP_PATH" "$DEST_PATH"
        return 0
    fi
    rm -f "$TEMP_PATH"
    return 1
}

sync_dashboard() {
    TOKEN="$(get_token)"
    if [ -z "$TOKEN" ]; then
        return 1
    fi

    download_blob /data/index.html "__DASHBOARD_BLOB_NAME__" || return 1
__ASSET_DOWNLOAD_BLOCK__
    return 0
}

if ! sync_dashboard; then
    echo "Initial dashboard sync failed; serving the last available local copy if present." >&2
fi

(
    while true; do
        sleep "$SYNC_INTERVAL_SECONDS"
        sync_dashboard || true
    done
) &

if [ ! -s /data/index.html ]; then
  cat > /data/index.html << 'PLACEHOLDER'
<!DOCTYPE html><html><head><title>Dashboard</title></head><body style="font-family:sans-serif;display:flex;justify-content:center;align-items:center;height:100vh;margin:0;background:#1a1a2e;color:#e0e0e0"><div style="text-align:center"><h1>Vulnerability Dashboard</h1><p>The dashboard has not been generated yet.</p><p>Publish the compute lane and run the pipeline to populate hosted content.</p></div></body></html>
PLACEHOLDER
fi
exec caddy file-server --root /data --listen :80
'''
var startupScript = replace(
  replace(
    replace(
      replace(startupScriptTemplate, '__STORAGE_ACCOUNT_NAME__', storageAccountName),
      '__STORAGE_DNS_SUFFIX__',
      storageDnsSuffix
    ),
    '__DASHBOARD_BLOB_NAME__',
    dashboardBlobName
  ),
  '__ASSET_DOWNLOAD_BLOCK__',
  assetDownloadBlock
)
var containerStartupCommand = replace(startupScript, '\r\n', '\n')

resource managedEnvironment 'Microsoft.App/managedEnvironments@2024-03-01' = {
  name: environmentName
  location: location
  properties: {
    appLogsConfiguration: {
      destination: 'log-analytics'
      logAnalyticsConfiguration: {
        customerId: logAnalyticsWorkspace.properties.customerId
        sharedKey: logAnalyticsWorkspace.listKeys().primarySharedKey
      }
    }
  }
}

resource containerApp 'Microsoft.App/containerApps@2024-03-01' = {
  name: containerAppName
  location: location
  identity: {
    type: 'SystemAssigned'
  }
  properties: {
    managedEnvironmentId: managedEnvironment.id
    configuration: {
      activeRevisionsMode: 'Single'
      ingress: {
        allowInsecure: false
        external: true
        targetPort: 80
        transport: 'auto'
      }
    }
    template: {
      containers: [
        {
          image: image
          name: 'caddy'
          command: [
            '/bin/sh'
            '-c'
          ]
          args: [
            containerStartupCommand
          ]
          resources: {
            cpu: json('0.25')
            memory: '0.5Gi'
          }
          volumeMounts: [
            {
              volumeName: 'dashboard-data'
              mountPath: '/data'
            }
          ]
        }
      ]
      volumes: [
        {
          name: 'dashboard-data'
          storageType: 'EmptyDir'
        }
      ]
      scale: {
        minReplicas: 0
        maxReplicas: 1
      }
    }
  }
}

output name string = containerApp.name
output url string = 'https://${containerApp.properties.configuration.ingress.fqdn}'
output identityPrincipalId string = containerApp.identity.principalId
