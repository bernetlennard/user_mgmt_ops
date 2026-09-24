# Das ganze Projekt auf einer Seite

Einstieg ins TEKO-Projekt *Verteilte Systeme*, ohne technische Details. Eine kleine Web-App zur
Benutzerverwaltung läuft in der Cloud. Darum herum haben wir in sechs Aufgaben aufgebaut, was ein
echter Betrieb braucht: **messen, testen, automatisch ausliefern, absichern**.

Die Details stehen in den READMEs der einzelnen Ordner (siehe [Wo finde ich was](#wo-finde-ich-was)).

## Was läuft wo

```mermaid
flowchart LR
  user(["Du im Browser"])
  phone(["Dein Handy<br/>(ntfy)"])

  subgraph DO["DigitalOcean-Cloud · Frankfurt"]
    subgraph K8S["Kubernetes-Cluster"]
      traefik["Traefik<br/>Eingangstür"]
      subgraph APP["je 1× in staging und prod"]
        fe["Frontend<br/>auth_portal"]
        be["Backend<br/>user_mgmt_service"]
        ms["module_service<br/>neu in Aufgabe 6"]
      end
      mon["Prometheus + Grafana<br/>misst & zeigt"]
      kyv["Kyverno<br/>Hausregeln"]
      argo["ArgoCD<br/>liefert aus"]
    end
    pg[("PostgreSQL<br/>Benutzer")]
    my[("MySQL<br/>Module")]
  end

  user -->|HTTPS| traefik
  traefik -->|Seiten| fe
  traefik -->|"/api"| be
  be -->|Benutzer-Daten| pg
  be -->|"fragt nach<br/>(Retry + Circuit Breaker)"| ms
  ms --> my
  mon -.->|Alarm| phone

  classDef app fill:#E6EDFA,stroke:#2F63C9,color:#17211D
  classDef data fill:#E1F2E9,stroke:#1B7F54,color:#17211D
  classDef ship fill:#F7ECD8,stroke:#A8680C,color:#17211D
  classDef watch fill:#EDE6F8,stroke:#7049BD,color:#17211D
  classDef plain fill:#EBEFEC,stroke:#46524D,color:#17211D
  class fe,be,ms app
  class pg,my data
  class argo ship
  class mon,kyv watch
  class user,phone,traefik plain
```

Farben: **blau** = die Programme der App, **grün** = Daten, **orange** = Ausliefern, **lila** = Aufpassen.

Frontend, Backend und module_service laufen je einmal in **staging** (Testversion) und in **prod**
(die echte). Traefik, Monitoring, Kyverno und ArgoCD gibt es nur einmal für den ganzen Cluster.

| Baustein | Was er macht | Vergleich |
|---|---|---|
| **Traefik** | Eingangstür: Webseiten gehen ans Frontend, alles unter `/api` ans Backend | Rezeption eines Hotels |
| **Frontend** (`auth_portal`) | die Seiten, die man sieht (Login, Benutzerliste); hat selbst keine Daten | Schaufenster |
| **Backend** (`user_mgmt_service`) | Herz der App (Java): Login, Benutzer, Modul-Zuweisung; bei Last automatisch mehr Kopien | Sekretariat, das alles koordiniert |
| **module_service** | eigener kleiner Dienst (Python), der die Module kennt und wer welches hat | Kursbüro mit eigener Modulliste |
| **PostgreSQL** | Benutzer-Datenbank, von DigitalOcean betrieben, per Terraform angelegt | gemieteter Aktenschrank |
| **MySQL** | Modul-Datenbank, **nur** der module_service kommt hin (auch übers Netz nicht das Backend) | zweiter Schrank, nur das Kursbüro hat den Schlüssel |
| **Prometheus + Grafana** | sammeln Messwerte (Anfragen, Fehler, Antwortzeit, CPU) und zeigen Dashboards; Regeln lösen Alarme aus | Fieberthermometer + Kurvenblatt |
| **Kyverno** | lässt nur rein, was die Hausregeln erfüllt (Limits, feste Version, Gesundheitschecks, keine Sonderrechte) | Türsteher mit Checkliste |
| **ArgoCD** | gleicht den Cluster ständig mit dem Ops-Repo ab; wer etwas ändern will, ändert das Repo | Hauswart, der alles nach Plan hinstellt |

## Was passiert, wenn man ein Modul zuweist

```mermaid
sequenceDiagram
  actor Du
  participant T as Traefik
  participant B as Backend
  participant M as module_service
  participant DB as MySQL

  Du->>T: Modul zuweisen
  T->>B: weiterreichen (/api)
  B->>B: angemeldet? darf das?
  B->>M: gibt es dieses Modul?
  alt Modul gibt es
    M->>DB: nachschauen + Zuweisung speichern
    B-->>Du: 200 OK
  else Modul gibt es nicht
    M-->>B: 404
    B-->>Du: 404 "Modul nicht verfügbar"
  else module_service ist weg
    B->>M: 3 Versuche mit kurzen Pausen (Retry)
    Note over B: danach fliegt die Sicherung raus (Circuit Breaker):<br/>weitere Anfragen werden sofort abgelehnt
    B-->>Du: 503 "gerade nicht verfügbar, in 15 s nochmal"
    Note over B,M: nach 2 Min. ohne module_service: Alarm aufs Handy.<br/>Ist er zurück, schliesst sich die Sicherung von selbst.
  end
```

Statuscodes: `200` OK · `400` Eingabe falsch · `403` nicht erlaubt · `404` gibt's nicht · `503` Dienst kurz weg

## Vom Code bis live

Niemand installiert von Hand. Eine Änderung löst eine Kette aus, und jeder Schritt hängt vom
vorherigen ab. Rot markiert ist, wo die Kette abbricht; dann geht nichts Kaputtes live.

```mermaid
flowchart TD
  tf["Einmalig vorher: Terraform baut<br/>Cluster + beide Datenbanken"]
  s1["1 · Code ändern & pushen<br/>(App-Repo auf GitHub)"]
  s2{"2 · Pipeline testet"}
  x2["Stopp: es wird nichts gebaut"]
  s3["3 · Image bauen<br/>(Paket mit Versionsnummer → Docker Hub)"]
  s4["4 · Pipeline schreibt die neue Version<br/>ins Ops-Repo"]
  s5["5 · ArgoCD rollt aus<br/>(staging + prod)"]
  s6{"6 · Kyverno: Hausregeln erfüllt?"}
  x6["Abgewiesen: alte Version läuft weiter"]
  s7["7 · Läuft und wird beobachtet<br/>(Prometheus + Grafana)"]
  a7["Problem? Alarm aufs Handy"]

  tf -.-> s1 --> s2
  s2 -->|grün| s3
  s2 -->|rot| x2
  s3 --> s4 --> s5 --> s6
  s6 -->|ja| s7
  s6 -->|nein| x6
  s7 -.-> a7

  classDef ship fill:#F7ECD8,stroke:#A8680C,color:#17211D
  classDef watch fill:#EDE6F8,stroke:#7049BD,color:#17211D
  classDef bad fill:#FBE6E2,stroke:#B8362A,color:#17211D
  class tf,s1,s2,s3,s4,s5 ship
  class s6,s7,a7 watch
  class x2,x6 bad
```

- **App-Repos** (Code): `linosteiner/user_mgmt_service`, `linosteiner/auth_portal`, `linosteiner/module_service`
- **Ops-Repo** (Bauplan für den Betrieb): `bernetlennard/user_mgmt_ops`, dieses Repo

## Die sechs Aufgaben, je ein Satz

| # | Aufgabe | In einem Satz | Wo im Bild |
|---|---|---|---|
| 1 | **Observability** | Prometheus sammelt Messwerte, Grafana zeigt sie als Dashboards, Alarme gehen über ntfy aufs Handy. | Prometheus + Grafana |
| 2 | **Chaos Testing** | Mit k6 simulieren wir viele Nutzer; das Backend startet automatisch zusätzliche Kopien und bleibt erreichbar. | Backend |
| 3 | **Terraform Infrastructure as Code** | Statt in der DigitalOcean-Oberfläche zu klicken, beschreibt eine Textdatei, was existieren soll, und Terraform stellt es so her. | Cluster, Datenbanken |
| 4 | **Managed Ressources** | Die Datenbank läuft nicht mehr selbst im Cluster, sondern als fertiger Dienst von DigitalOcean. | PostgreSQL |
| 5 | **Kyverno Policy as Code** | Hausregeln für den Cluster: Wer sie bricht, wird schon beim Ausliefern abgewiesen. | Kyverno |
| 6 | **Microservices** (40 % der Note) | Neuer module_service mit eigener MySQL; das Backend fragt ihn übers Netz und ist gegen seinen Ausfall abgesichert. | module_service, MySQL |

## Wo finde ich was

| Thema | Ort | Wie es live geht |
|---|---|---|
| App im Cluster (Frontend, Backend, module_service, Netzwerkregeln, Alarme) | [`charts/user-mgmt/`](../charts/user-mgmt/) | automatisch über ArgoCD, sobald auf `main` |
| Monitoring (Prometheus, Grafana, Dashboards, Alarm → ntfy) | [`monitoring/`](../monitoring/) | von Hand mit `helm upgrade` |
| Lasttests (k6) und Resultate | [`k6/`](../k6/) | von Hand mit `kubectl apply` |
| Kyverno-Regeln | [`policy/`](../policy/) | Regeln über ArgoCD, Kyverno selbst von Hand |
| Cluster + Datenbanken (Terraform) | [`terraform/`](../terraform/) | von Hand mit `terraform apply` |
| ArgoCD-Anwendungen | [`argocd/`](../argocd/) | einmalig `kubectl apply` |
| Aufgabe 6 im Detail, mit allen Nachweisen | [`docs/module-service.md`](module-service.md) | – |

**Wichtig für die Zusammenarbeit:**

- Den Terraform-State (`terraform/terraform.tfstate`) gibt es nur als eine gültige Kopie, weil er
  nicht im Repo liegt. Nach jedem `terraform apply` muss er an die andere Person weitergegeben werden.
- Passwörter liegen nie im Repo. Sie liegen als Kubernetes-Secrets im Cluster und werden aus den
  Terraform-Ausgaben erzeugt.

## Wörter, die überall vorkommen

| Wort | Bedeutung |
|---|---|
| **Container / Image** | ein Programm samt allem, was es braucht, fertig verpackt; das Image ist die Verpackung, der Container die laufende Kopie |
| **Kubernetes** | verwaltet viele Container: startet sie, ersetzt abgestürzte, verteilt die Last |
| **Pod** | eine laufende Kopie eines Programms (das Backend hat je nach Last 1–3 davon) |
| **staging / prod** | zwei getrennte Welten im selben Cluster, eine zum Ausprobieren, eine für echt |
| **Helm-Chart** | die Vorlage, aus der alle Kubernetes-Einstellungen der App erzeugt werden |
| **GitOps** | was im Ops-Repo steht, gilt; ArgoCD sorgt dafür, dass der Cluster genau so aussieht |
| **Pipeline** | automatische Schritte nach jedem Push: testen, bauen, Version eintragen |
| **Circuit Breaker** | wie die Sicherung im Stromkasten: bei zu vielen Fehlern wird sofort abgelehnt, statt immer wieder zu warten |

---

*Stand 24.09.2026*
