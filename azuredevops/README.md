.
├── azure-pipelines.yml          # Entry point
├── templates/
│   ├── build.yml
│   ├── sonar.yml
│   ├── nexusiq.yml
│   ├── trivy.yml
│   ├── snyk.yml
│   ├── docker.yml
│   └── deploy-function.yml
├── app.py
├── requirements.txt
├── Dockerfile
└── tests/

[Stage: Build & SAST]
│
▼
[Stage: Deploy Dev]
│
▼
[Stage: Deploy Staging]
│
▼
(Approvazione Manuale)
│
▼
[Stage: Deploy Production]

Prima di scrivere lo YAML, l'infrastruttura di Azure DevOps viene configurata nella sezione **Library** e **Project Settings**:

1. **Variable Groups**:
   * `sonar-configuration`: Contiene `SONAR_PROJECT_KEY` e `SONAR_ORGANIZATION`.
   * `app-secrets-prod` (Secret): Contiene la password di produzione o le stringhe di connessione criptate (icona lucchetto 🔒).
2. **Secure Files**:
   * `kubeconfig-cluster-ext`: File kubeconfig protetto caricato per configurazioni avanzate di K8s.
3. **Service Connections**:
   * `sonarqube-conn`: Connessione di tipo *SonarQube Server*.
   * `k8s-dev-conn`, `k8s-stage-conn`, `k8s-prod-conn`: Connessioni al cluster Kubernetes (con permessi RBAC limitati al rispettivo Namespace).

---

## 3. I Template Riutilizzabili (Approccio DRY)

Per evitare la duplicazione del codice per i tre ambienti di deploy, astraiamo la logica del rilascio in un template parametrizzato.

### Template di Rilascio Kubernetes (`templates/k8s-deploy-template.yml`)

```yaml
# File: templates/k8s-deploy-template.yml
parameters:
  - name: stageName
    type: string
  - name: displayName
    type: string
  - name: environmentName
    type: string
  - name: serviceConnection
    type: string
  - name: dependsOnStage
    type: string
    default: ''

stages:
  - stage: ${{ parameters.stageName }}
    displayName: ${{ parameters.displayName }}
    dependsOn: ${{ parameters.dependsOnStage }}
    condition: succeeded()
    jobs:
      - deployment: DeployJob
        displayName: 'Deploy K8s Job'
        environment: ${{ parameters.environmentName }}
        strategy:
          runOnce:
            deploy:
              steps:
                - checkout: self

                # Manifest Bake & Deploy standard su Kubernetes
                - task: KubernetesManifest@1
                  displayName: 'Deploy su Cluster K8s'
                  inputs:
                    action: 'deploy'
                    connectionType: 'Kubernetes Service Connection'
                    kubernetesServiceConnection: ${{ parameters.serviceConnection }}
                    namespace: ${{ lower(parameters.stageName) }}
                    manifests: |
                      $(System.DefaultWorkingDirectory)/k8s/deployment.yml
                      $(System.DefaultWorkingDirectory)/k8s/service.yml
                    imagePullSecrets: 'acr-secret'

```

---

## 4. La Pipeline Principale (`azure-pipelines.yml`)

La pipeline orchestratrice unisce la fase di Build, i controlli SAST con il Quality Gate e richiama il template per i progressivi rilasci negli ambienti.

```yaml
# File: azure-pipelines.yml
trigger:
  - main

resources:
  repositories:
    - repository: self

pools:
  vmImage: 'ubuntu-latest'

variables:
  - group: 'sonar-configuration' # Importazione del Variable Group globale
  - name: buildConfiguration
    value: 'Release'

stages:
  # ==========================================
  # STAGE 1: BUILD, TEST & SAST (SONARQUBE)
  # ==========================================
  - stage: BuildAndTest
    displayName: 'Build, Test & Quality Gate'
    jobs:
      - job: CompileAndAnalyze
        displayName: '.NET Build e Analisi Codice'
        steps:
          - checkout: self
            fetchDepth: 0 # Richiesto da SonarQube per l'analisi dei blame Git

          # Inizializzazione dell'analisi SonarQube
          - task: SonarQubePrepare@7
            displayName: 'Inizializza SonarQube'
            inputs:
              SonarQube: 'sonarqube-conn' # Service Connection
              scannerMode: 'MSBuild'
              projectKey: '$(SONAR_PROJECT_KEY)'
              projectName: 'DotNetK8sApp'

          # Ripristino e Compilazione dell'applicazione .NET
          - task: DotNetCoreCLI@2
            displayName: 'Restore Dependencies'
            inputs:
              command: 'restore'
              projects: '**/*.csproj'

          - task: DotNetCoreCLI@2
            displayName: 'Build Application'
            inputs:
              command: 'build'
              projects: '**/*.csproj'
              arguments: '--configuration $(buildConfiguration)'

          # Esecuzione Test Unitari
          - task: DotNetCoreCLI@2
            displayName: 'Esecuzione Unit Tests'
            inputs:
              command: 'test'
              projects: '**/*Tests.csproj'
              arguments: '--configuration $(buildConfiguration)'

          # Chiusura Analisi SonarQube (Invia i dati al server)
          - task: SonarQubeAnalyze@7
            displayName: 'Esegui Analisi Codice'

          # Quality Gate: Blocca la pipeline se l'analisi fallisce i requisiti minimi
          - task: SonarQubePublish@7
            displayName: 'Pubblica Risultati Quality Gate'
            inputs:
              pollingTimeoutSec: '300'

  # ==========================================
  # STAGE 2: DEPLOY DEV
  # ==========================================
  - template: templates/k8s-deploy-template.yml
    parameters:
      stageName: 'Dev'
      displayName: 'Rilascio in Ambiente Sviluppo'
      environmentName: 'Development-Cluster'
      serviceConnection: 'k8s-dev-conn'
      dependsOnStage: 'BuildAndTest'

  # ==========================================
  # STAGE 3: DEPLOY STAGING
  # ==========================================
  - template: templates/k8s-deploy-template.yml
    parameters:
      stageName: 'Staging'
      displayName: 'Rilascio in Ambiente Staging'
      environmentName: 'Staging-Cluster'
      serviceConnection: 'k8s-stage-conn'
      dependsOnStage: 'Dev'

  # ==========================================
  # STAGE 4: DEPLOY PRODUCTION (Con Blocco Approva)
  # ==========================================
  # NOTA: Il blocco di approvazione viene applicato sull'Environment "Production-Cluster" 
  # tramite la UI di Azure DevOps (Library -> Environments -> Approvals and checks).
  - template: templates/k8s-deploy-template.yml
    parameters:
      stageName: 'Production'
      displayName: 'Rilascio in Ambiente Produzione'
      environmentName: 'Production-Cluster'
      serviceConnection: 'k8s-prod-conn'
      dependsOnStage: 'Staging'
