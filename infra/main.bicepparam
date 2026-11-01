// Parameters for infra/main.bicep. Replace the placeholder values before deploying.
// The image tag and Entra values come from environment variables, so no ID or
// secret is written here: infra/setup-entra.sh writes them to .env.entra
// (source it), and you set PULLPICKET_IMAGE_TAG after pushing the image.
// With PULLPICKET_IMAGE_TAG unset, the deployment skips the Container App.
using 'main.bicep'

param namePrefix = 'pullpicket'

param imageTag = readEnvironmentVariable('PULLPICKET_IMAGE_TAG', '')

param apiAppIdUri = readEnvironmentVariable('PULLPICKET_API_APP_ID_URI', '')

param apiClientId = readEnvironmentVariable('PULLPICKET_API_CLIENT_ID', '')

param dashboardClientId = readEnvironmentVariable('PULLPICKET_DASHBOARD_CLIENT_ID', '')

param dashboardClientSecret = readEnvironmentVariable('PULLPICKET_DASHBOARD_CLIENT_SECRET', '')

param tags = {
  application: 'pullpicket'
  environment: 'dev'
}
