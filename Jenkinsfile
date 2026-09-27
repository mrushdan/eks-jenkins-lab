// Every stage runs in a short-lived pod on EKS. The Jenkins controller runs no builds.
// Environment provided by the controller (Configuration as Code):
//   AWS_REGION, CLUSTER_NAME, TF_STATE_BUCKET, ECR_REPO_NAME

pipeline {
  agent {
    kubernetes {
      defaultContainer 'tools'
      yaml '''
apiVersion: v1
kind: Pod
spec:
  # Bound to an IAM role through EKS Pod Identity (ECR, S3 state, EKS access).
  serviceAccountName: jenkins-agent
  containers:
    - name: tools
      image: alpine/k8s:1.35.6          # aws cli, kubectl, curl
      command: ["cat"]
      tty: true
      resources:
        requests: { cpu: 100m, memory: 128Mi }
    - name: terraform
      image: hashicorp/terraform:1.16.4
      command: ["cat"]
      tty: true
      resources:
        requests: { cpu: 100m, memory: 256Mi }
    - name: kaniko
      # Maintained Chainguard fork of Kaniko (the Google original was archived in 2025).
      image: registry.gitlab.com/gitlab-ci-utils/container-images/kaniko:debug
      command: ["/busybox/cat"]
      tty: true
      resources:
        requests: { cpu: 250m, memory: 512Mi }
        limits: { memory: 1536Mi }
'''
    }
  }

  options {
    timestamps()
    timeout(time: 30, unit: 'MINUTES')
    disableConcurrentBuilds()
    buildDiscarder(logRotator(numToKeepStr: '20'))
  }

  triggers {
    githubPush()
  }

  parameters {
    choice(
      name: 'FAIL_ON_SEVERITY',
      choices: ['CRITICAL', 'HIGH', 'NONE'],
      description: 'Fail the build if the ECR scan finds vulnerabilities at or above this severity.'
    )
  }

  environment {
    APP_NAMESPACE = 'demo-app'
    APP_NAME      = 'demo-app'
    KUBECONFIG    = "${WORKSPACE}/.kube/config"
  }

  stages {

    stage('Version') {
      steps {
        script {
          env.APP_VERSION   = readFile('app/VERSION').trim()
          env.GIT_SHORT_SHA = env.GIT_COMMIT.take(7)
          env.IMAGE_TAG     = "${env.APP_VERSION}-${env.GIT_SHORT_SHA}"
          currentBuild.displayName = "#${env.BUILD_NUMBER} ${env.IMAGE_TAG}"
        }
        echo "Image tag: ${env.IMAGE_TAG}"
      }
    }

    stage('Terraform: app stack') {
      steps {
        container('terraform') {
          sh '''
            cd infra/app
            terraform init -input=false \
              -backend-config="bucket=${TF_STATE_BUCKET}" \
              -backend-config="region=${AWS_REGION}"
            terraform apply -input=false -auto-approve \
              -var="aws_region=${AWS_REGION}" \
              -var="repository_name=${ECR_REPO_NAME}"
            terraform output -raw repository_url > "${WORKSPACE}/.ecr_repo_url"
          '''
        }
        script {
          env.ECR_REPO_URL = readFile('.ecr_repo_url').trim()
          env.ECR_REGISTRY = env.ECR_REPO_URL.tokenize('/')[0]
        }
        echo "ECR repository: ${env.ECR_REPO_URL}"
      }
    }

    stage('Build and push (Kaniko)') {
      steps {
        // Short-lived ECR login written where Kaniko can read it. xtrace is off so the token never hits the log.
        sh '''#!/bin/sh -e
          mkdir -p "${WORKSPACE}/.docker"
          PASS=$(aws ecr get-login-password --region "${AWS_REGION}")
          AUTH=$(printf 'AWS:%s' "${PASS}" | base64 | tr -d '\\n')
          printf '{"auths":{"%s":{"auth":"%s"}}}' "${ECR_REGISTRY}" "${AUTH}" > "${WORKSPACE}/.docker/config.json"
          echo "ECR credentials written for ${ECR_REGISTRY}"
        '''
        container(name: 'kaniko', shell: '/busybox/sh') {
          sh '''#!/busybox/sh -e
            export DOCKER_CONFIG="${WORKSPACE}/.docker"
            /kaniko/executor \
              --context "dir://${WORKSPACE}/app" \
              --dockerfile "${WORKSPACE}/app/Dockerfile" \
              --build-arg "APP_VERSION=${IMAGE_TAG}" \
              --destination "${ECR_REPO_URL}:${IMAGE_TAG}" \
              --destination "${ECR_REPO_URL}:latest"
          '''
        }
      }
    }

    stage('ECR image scan') {
      steps {
        sh '''#!/bin/sh -e
          echo "Waiting for scan-on-push to finish for ${IMAGE_TAG}..."
          aws ecr wait image-scan-complete --region "${AWS_REGION}" \
            --repository-name "${ECR_REPO_NAME}" --image-id imageTag="${IMAGE_TAG}"

          count() {
            n=$(aws ecr describe-image-scan-findings --region "${AWS_REGION}" \
                  --repository-name "${ECR_REPO_NAME}" --image-id imageTag="${IMAGE_TAG}" \
                  --query "imageScanFindings.findingSeverityCounts.$1" --output text)
            [ "$n" = "None" ] && n=0
            echo "$n"
          }

          CRITICAL=$(count CRITICAL)
          HIGH=$(count HIGH)
          MEDIUM=$(count MEDIUM)
          echo "Findings: CRITICAL=${CRITICAL} HIGH=${HIGH} MEDIUM=${MEDIUM}"

          case "${FAIL_ON_SEVERITY}" in
            CRITICAL) BLOCKING=${CRITICAL} ;;
            HIGH)     BLOCKING=$((CRITICAL + HIGH)) ;;
            *)        BLOCKING=0 ;;
          esac

          if [ "${BLOCKING}" -gt 0 ]; then
            echo "Blocking: ${BLOCKING} finding(s) at or above ${FAIL_ON_SEVERITY}."
            exit 1
          fi
          echo "Scan gate passed (threshold: ${FAIL_ON_SEVERITY})."
        '''
      }
    }

    stage('Deploy to EKS') {
      steps {
        sh '''#!/bin/sh -e
          mkdir -p "$(dirname "${KUBECONFIG}")"
          aws eks update-kubeconfig --region "${AWS_REGION}" --name "${CLUSTER_NAME}" --kubeconfig "${KUBECONFIG}"

          rm -rf rendered && mkdir rendered && cp k8s/*.yaml rendered/
          sed -i "s|IMAGE_PLACEHOLDER|${ECR_REPO_URL}:${IMAGE_TAG}|g; s|VERSION_PLACEHOLDER|${IMAGE_TAG}|g" rendered/deployment.yaml

          kubectl apply -f rendered/namespace.yaml
          kubectl apply -f rendered/
          kubectl -n "${APP_NAMESPACE}" rollout status "deployment/${APP_NAME}" --timeout=180s
          kubectl -n "${APP_NAMESPACE}" get pods -o wide
        '''
      }
    }

    stage('Smoke test (ALB)') {
      steps {
        sh '''#!/bin/sh -e
          echo "Waiting for the ALB hostname..."
          HOST=""
          for i in $(seq 1 30); do
            HOST=$(kubectl -n "${APP_NAMESPACE}" get ingress "${APP_NAME}" -o jsonpath='{.status.loadBalancer.ingress[0].hostname}')
            [ -n "${HOST}" ] && break
            sleep 10
          done
          [ -z "${HOST}" ] && { echo "Ingress never got an ALB hostname"; kubectl -n "${APP_NAMESPACE}" describe ingress "${APP_NAME}"; exit 1; }
          echo "${HOST}" > "${WORKSPACE}/.alb_host"
          echo "ALB: http://${HOST}/"

          # A brand-new ALB takes a few minutes for DNS and target health.
          for i in $(seq 1 40); do
            BODY=$(curl -fsS --max-time 5 "http://${HOST}/" 2>/dev/null || true)
            if echo "${BODY}" | grep -q "${IMAGE_TAG}"; then
              echo "Smoke test passed: ${BODY}"
              curl -fsS "http://${HOST}/healthz"
              echo
              exit 0
            fi
            echo "Attempt ${i}: not serving ${IMAGE_TAG} yet"
            sleep 15
          done
          echo "Smoke test failed: ALB never served ${IMAGE_TAG}"
          exit 1
        '''
        script {
          env.APP_URL = "http://${readFile('.alb_host').trim()}/"
          currentBuild.description = env.APP_URL
        }
      }
    }
  }

  post {
    success {
      echo "Deployed ${env.IMAGE_TAG} to ${env.APP_URL}"
    }
    failure {
      echo 'Build failed. Check the stage logs above; build pod is deleted automatically.'
    }
  }
}
