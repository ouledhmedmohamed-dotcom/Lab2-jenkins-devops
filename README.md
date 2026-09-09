# Lab2 - Chaine CI Jenkins

## Contexte

Formation DevOps - Linqiny
Module: Pratique II - Intégration Continue

## Objectif

Mettre en place une chaîne CI avec Jenkins et Git : installation de Jenkins, création d'un exemple Java/Maven, publication sur GitHub, et build automatique via Jenkins piloté par un `Jenkinsfile` versionné (pipeline as code).

## Architecture

Dev (git push) --> GitHub (main) --> Jenkins (webhook / poll SCM)
|
v
Jenkinsfile (pipeline)
Checkout -> Build -> Test -> Package -> Archive


## Prérequis

- VM CentOS7 (ou équivalent)
- Accès sudo
- Connexion réseau vers pkg.jenkins.io et api.adoptium.net

## Étapes réalisées

1. Création d'une VM CentOS7 dédiée à Jenkins
2. Correction des dépôts CentOS7 (EOL) pour pointer vers `vault.centos.org`
3. Installation du JDK 21 Temurin (Eclipse Adoptium) et configuration via `alternatives`
4. Installation de Jenkins (dépôt officiel `pkg.jenkins.io`)
5. Configuration systemd (écoute sur `0.0.0.0`, `TimeoutStartSec=600`)
6. Ouverture du port 8080 sur le firewall
7. Activation et vérification du service Jenkins
8. Création d'un exemple Java simple (`App.java` + `AppTest.java`) avec Maven
9. Build local réussi avec `mvn clean package`
10. Publication du code sur GitHub
11. Création d'un job Jenkins de type **Pipeline**, pointant sur ce dépôt et sur le `Jenkinsfile` (Pipeline script from SCM)
12. Build automatique déclenché à chaque push sur `main`

## Installation Jenkins

Le script [`install-jenkins.sh`](./install-jenkins.sh) automatise les étapes 2 à 7 ci-dessus. À exécuter sur la VM cible :

```bash
chmod +x install-jenkins.sh
./install-jenkins.sh
```

Jenkins est ensuite accessible sur `http://<IP_VM>:8080`.

## Build local du projet Maven

```bash
mvn clean package
```

Le jar généré se trouve dans `target/`.

## Pipeline Jenkins

Le job Jenkins est configuré en **Pipeline script from SCM** :
- SCM : Git
- Repository URL : ce dépôt
- Branch : `main`
- Script Path : `Jenkinsfile`

Le `Jenkinsfile` définit 4 étapes : `Checkout`, `Build`, `Test` (avec publication des résultats JUnit), `Package`, `Archive` (archivage du `.jar`).

## Structure du projet

.
├── Jenkinsfile
├── install-jenkins.sh
├── pom.xml
├── README.md
└── src
├── main/java/... -> App.java
└── test/java/... -> AppTest.java


## Technologies utilisées

- CentOS7
- Jenkins (Pipeline as Code)
- Java 21 (Temurin) pour l'exécution de Jenkins / Java 1.8 (cible de compilation Maven)
- Maven
- Git / GitHub

## Auteur

Mohamed OuledHmed
