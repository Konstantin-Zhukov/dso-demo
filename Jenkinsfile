pipeline {
  environment {
    ARGO_SERVER = 'argocd-server.argocd.svc.cluster.local'
  }
  agent {
    kubernetes {
      yamlFile 'build-agent.yaml'
      defaultContainer 'maven'
      idleMinutes 1
    }
  }
  stages {
    stage('Build') {
      parallel {
        stage('Compile') {
          steps {
            container('maven') {
              sh 'mvn compile'
            }
          }
        }
      }
    }
    stage('Static Analysis') {
      parallel {
        stage('Unit Tests') {
          steps {
            container('maven') {
              sh 'mvn test'
            }
          }
        }
        stage('SCA') {
          steps {
            container('maven') {
              catchError(buildResult: 'SUCCESS', stageResult: 'FAILURE') {
                sh 'mvn org.owasp:dependency-check-maven:check'
              }
            }
          }
          post {
            always {
              archiveArtifacts allowEmptyArchive: true, artifacts: 'target/dependency-check-report.html', fingerprint: true, onlyIfSuccessful: true
            }
          }
        }
        stage('OSS License Checker') {
          steps {
            container('licensefinder') {
              sh 'ls -al'
              sh '''#!/bin/bash --login
                /bin/bash --login
                rvm use default
                gem install license_finder
                license_finder
              '''
            }
          }
        }
        stage('Generate SBOM') {
          steps {
            container('maven') {
              sh 'mvn org.cyclonedx:cyclonedx-maven-plugin:makeAggregateBom'
            }
          }
          post {
            success {
              archiveArtifacts allowEmptyArchive: true, artifacts: 'target/bom.xml',
                fingerprint: true, onlyIfSuccessful: true
            }
          }
        }
      }
    }
    stage('SAST') {
      steps {
        container('semgrep') {
      sh '''
        mkdir -p reports
        semgrep --config=auto --sarif --output=reports/semgrep-report.sarif . || true
        semgrep --config=auto --json --output=reports/semgrep-report.json . || true
      '''
    }
      }
      post {
        success {
          archiveArtifacts allowEmptyArchive: true, artifacts: 'reports/*',
            fingerprint: true, onlyIfSuccessful: true
        }
      }
    }
    stage('Package') {
      parallel {
        stage('Create Jarfile') {
          steps {
            container('maven') {
              sh 'mvn package -DskipTests'
            }
          }
        }
      }
    }

    stage('Docker Build and Push') {
      steps {
        container('kaniko') {
          withCredentials([usernamePassword(credentialsId: 'dockerhub-creds', usernameVariable: 'DOCKERHUB_USER', passwordVariable: 'DOCKERHUB_PASS')]) {
            sh '''
              AUTH=$(echo -n "$DOCKERHUB_USER:$DOCKERHUB_PASS" | base64 | tr -d '\\n')
              mkdir -p /kaniko/.docker
              echo "{\\"auths\\":{\\"https://index.docker.io/v1/\\":{\\"auth\\":\\"$AUTH\\"}}}" > /kaniko/.docker/config.json
              /kaniko/executor \\
                --context=$(pwd) \\
                --dockerfile=$(pwd)/Dockerfile \\
                --destination=kostetych/dso-demo:${BUILD_NUMBER} \\
                --destination=kostetych/dso-demo:latest
            '''
          }
        }
      }
    }

    stage('Deploy to Dev') {
      environment {
        AUTH_TOKEN = credentials('argocd-jenkins-deployer-token')
      }
      steps {
        container('argocd-cli') {
          sh 'argocd app sync dso-demo --insecure --server $ARGO_SERVER --auth-token $AUTH_TOKEN'
          sh 'argocd app wait dso-demo --health --timeout 300 --insecure --server $ARGO_SERVER --auth-token $AUTH_TOKEN'
        }
      }
    }
  }
}