// ============================================================
//  Pipeline CI/CD - Lab2 (architecture 4 VM)
//  Agent : admin-agent (VM4 CentOS : Java 21, Maven, Git, JMeter, Tomcat)
//  Les valeurs marquées TODO sont à adapter à ton environnement.
// ============================================================
pipeline {
    agent { label 'admin-agent' }

    options {
        timestamps()
        timeout(time: 45, unit: 'MINUTES')
        buildDiscarder(logRotator(numToKeepStr: '20'))
    }

    triggers {
        pollSCM('H/2 * * * *')          // build automatique après chaque commit
    }

    environment {
        NEXUS_SERVER_ID = 'nexus'                 // = <id> du distributionManagement dans pom.xml
        SONAR_SERVER    = 'sonarqube'             // nom du serveur (Manage Jenkins > System)
        TOMCAT_WEBAPPS  = '/opt/tomcat/webapps'   // TODO: dossier webapps de Tomcat sur VM4
        TOMCAT_URL      = 'http://localhost:8080' // TODO: URL de Tomcat vu depuis VM4
        JMETER_PLAN     = 'tests/jmeter/plan.jmx' // TODO: chemin du plan JMeter dans le repo
        MAIL_TO         = 'ouledhmedmohamed@gmail.com' // destinataire des notifications
    }

    stages {

        stage('Checkout Git') {
            steps {
                echo '=== Checkout Git ==='
                checkout scm
            }
        }

        stage('Vérification Java / Maven') {
            steps {
                sh '''
                    set -e
                    echo "=== JAVA_HOME ===";  echo "${JAVA_HOME:-non défini}"
                    echo "=== Java ===";       which java;  java -version
                    echo "=== Maven ===";      which mvn;   mvn -version
                    echo "=== Agent ===";      hostname;    hostname -I
                '''
            }
        }

        stage('Build Maven') {
            steps {
                sh 'mvn -B clean package -DskipTests'
            }
        }

        stage('Tests + couverture JaCoCo') {
            steps {
                // verify : exécute les tests ; JaCoCo génère son rapport si le plugin est dans le pom
                sh 'mvn -B verify'
            }
            post {
                always {
                    junit allowEmptyResults: true, testResults: '**/target/surefire-reports/*.xml'
                }
            }
        }

        stage('Analyse SonarQube') {
            steps {
                withSonarQubeEnv("${SONAR_SERVER}") {
                    sh 'mvn -B sonar:sonar -Dsonar.projectKey=Lab2-jenkins-devops -Dsonar.projectName=Lab2-jenkins-devops'
                }
            }
        }

        stage('Quality Gate') {
            steps {
                // nécessite le Webhook SonarQube -> http://<jenkins>:8080/sonarqube-webhook/
                timeout(time: 5, unit: 'MINUTES') {
                    waitForQualityGate abortPipeline: true
                }
            }
        }

        stage('Publication Nexus') {
            steps {
                withCredentials([usernamePassword(credentialsId: 'nexus-credentials',
                                                  usernameVariable: 'NEXUS_USER',
                                                  passwordVariable: 'NEXUS_PASS')]) {
                    sh '''
                        cat > "$WORKSPACE/settings-ci.xml" <<EOF
<settings>
  <servers>
    <server>
      <id>${NEXUS_SERVER_ID}</id>
      <username>${NEXUS_USER}</username>
      <password>${NEXUS_PASS}</password>
    </server>
  </servers>
</settings>
EOF
                        mvn -B -s "$WORKSPACE/settings-ci.xml" deploy -DskipTests
                        rm -f "$WORKSPACE/settings-ci.xml"
                    '''
                }
            }
        }

        stage('Archivage artefact') {
            steps {
                archiveArtifacts artifacts: 'target/*.war,target/*.jar', allowEmptyArchive: true, fingerprint: true
            }
        }

        stage('Déploiement Tomcat') {
            steps {
                sh '''
                    WAR=$(ls target/*.war 2>/dev/null | head -1 || true)
                    if [ -z "$WAR" ]; then
                        echo "Aucun WAR trouvé : déploiement Tomcat ignoré"
                        exit 0
                    fi
                    echo "Déploiement de $WAR vers ${TOMCAT_WEBAPPS}"
                    cp -f "$WAR" "${TOMCAT_WEBAPPS}/"
                '''
            }
        }

        stage('Smoke test applicatif') {
            steps {
                sh '''
                    WAR=$(ls target/*.war 2>/dev/null | head -1 || true)
                    [ -z "$WAR" ] && { echo "Pas de WAR, smoke test ignoré"; exit 0; }
                    APP=$(basename "$WAR" .war)
                    for i in $(seq 1 12); do
                        CODE=$(curl -s -o /dev/null -w '%{http_code}' "${TOMCAT_URL}/${APP}/" || true)
                        echo "Tentative $i : HTTP $CODE"
                        [ "$CODE" = "200" ] && exit 0
                        sleep 5
                    done
                    echo "L'application ne répond pas après le déploiement"
                    exit 1
                '''
            }
        }

        stage('Test de charge JMeter') {
            when { expression { fileExists(env.JMETER_PLAN) } }
            steps {
                sh '''
                    mkdir -p target/jmeter
                    rm -rf target/jmeter/report target/jmeter/results.jtl
                    jmeter -n -t "${JMETER_PLAN}" -l target/jmeter/results.jtl -e -o target/jmeter/report
                '''
                archiveArtifacts artifacts: 'target/jmeter/**', allowEmptyArchive: true
            }
        }
    }

    post {
        success {
            script {
                // un SMTP non configuré ne doit pas faire échouer le build
                try {
                    mail to: "${MAIL_TO}",
                         subject: "SUCCÈS : ${env.JOB_NAME} #${env.BUILD_NUMBER}",
                         body: "Pipeline terminé avec succès sur l'agent admin-agent.\nDétails : ${env.BUILD_URL}"
                } catch (err) {
                    echo "Mail non envoyé (SMTP à configurer) : ${err.message}"
                }
            }
        }
        failure {
            script {
                try {
                    mail to: "${MAIL_TO}",
                         subject: "ÉCHEC : ${env.JOB_NAME} #${env.BUILD_NUMBER}",
                         body: "Le pipeline a échoué.\nConsole : ${env.BUILD_URL}console"
                } catch (err) {
                    echo "Mail non envoyé (SMTP à configurer) : ${err.message}"
                }
            }
        }
    }
}
