# Mail Server add-on

Wrapper attorno all'immagine ufficiale [docker-mailserver](https://github.com/docker-mailserver/docker-mailserver),
con TLS condiviso via Let's Encrypt (vedi add-on `cloudflare_certbot`).

## Persistenza dati

L'immagine upstream scrive il suo stato in quattro percorsi non persistenti di
default (`/var/mail`, `/var/mail-state`, `/var/log/mail`, `/tmp/docker-mailserver`).
`run.sh` li rilinka sotto `/data` (l'unica cartella che Home Assistant conserva
tra un riavvio/aggiornamento dell'add-on e l'altro), quindi account, alias,
chiavi DKIM e mail non vengono persi quando l'add-on viene riavviato o
aggiornato.

## Aggiungere il repository su Home Assistant

1. Impostazioni → Componenti aggiuntivi → Store add-on.
2. Menu ⋮ (in alto a destra) → Repository.
3. Incolla `https://github.com/domysh/ha-custom-addons` → Aggiungi.
4. Chiudi e ricarica la pagina: "Mail Server" e "Cloudflare Certbot" compariranno nello store.
5. Installa entrambi (Cloudflare Certbot per primo, così i certificati in `/share/certs` esistono già quando parte il mailserver).

## Gestire gli account email

L'immagine include già il tool `setup` di docker-mailserver: non serve altro
che eseguirlo dentro al container in esecuzione, ad esempio con l'add-on
"SSH & Web Terminal" (o via SSH sull'host):

```sh
# nome del container: addon_<slug_repo>_mailserver, verificabile con:
docker ps --filter name=mailserver --format '{{.Names}}'

# aggiungere un account
docker exec -it addon_local_mailserver setup email add utente@tuodominio.it 'password'

# cambiare password
docker exec -it addon_local_mailserver setup email update utente@tuodominio.it 'nuova-password'

# elencare gli account
docker exec -it addon_local_mailserver setup email list

# rimuovere un account
docker exec -it addon_local_mailserver setup email del utente@tuodominio.it

# alias
docker exec -it addon_local_mailserver setup alias add info@tuodominio.it utente@tuodominio.it
```

Tutte le modifiche finiscono in `/data/config` (persistente) grazie al symlink
creato da `run.sh`.

## Importare dati da una vecchia installazione

Se hai già un'installazione docker-mailserver esistente (es. un vecchio
docker-compose) con cartelle tipo `mail-data/`, `mail-state/`, `config/`,
`logs/`, puoi migrarle così:

1. Installa e avvia una volta l'add-on "Mail Server" (crea `/data/mail`,
   `/data/mail-state`, `/data/log`, `/data/config`), poi fermalo dallo Store.
2. Trova il nome del container: `docker ps -a --filter name=mailserver --format '{{.Names}}'`.
3. Copia i dati vecchi dentro il container (funziona anche a container fermo):

   ```sh
   docker cp /percorso/vecchio/mail-data/.   addon_local_mailserver:/data/mail/
   docker cp /percorso/vecchio/mail-state/.  addon_local_mailserver:/data/mail-state/
   docker cp /percorso/vecchio/config/.      addon_local_mailserver:/data/config/
   docker cp /percorso/vecchio/logs/.        addon_local_mailserver:/data/log/
   ```

   (salta le cartelle che non hai: bastano `mail-data` + `config` per
   recuperare mailbox e account; `mail-state` contiene lo stato di
   fail2ban/amavis, `logs` è opzionale.)

4. Riavvia l'add-on dallo Store. Al boot troverà gli account già esistenti in
   `/data/config/postfix-accounts.cf` e le mail in `/data/mail`.
