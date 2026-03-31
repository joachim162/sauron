# TODO

- [ ] je endpoint /servers/{server}/zones/{zone}/hosts spravne?
  - resp. otazkou je jestli by tu nemel byt endpoint i pro ziskavi vsech hostu napric vsemi zonami a servery

## co implementovat do sauron API

- GET hosty v zone a vsechno o nich (napr. komentar)
- zalozit novy host
- NAPSTR
- SSHFP (uz je v devu)
- podivat se na katalogovou zonu v Suaron
- podivat se na DELEG DNS zaznam
- logovani (rozliseni uzivatele a API klice)
- autentizace/autorizace - vytvoreni klice v sauronovi (v CGI pod uzivatelem) a prideleni prav

## server

- implementovat CRUD

## zones

- implementovat CRUD

## hosts

### get_host

- [ ] opravit data z jinych tabulek (napr. SSHFP)

### add_host

- co jsem schopen jednoznacne urcit do ktere zony ma byt host prirazen jen na zaklade FQDN?

## CGI / Frontend

- [x] zprovoznit - pro lepsi prehled o tom co a jak funguje, jak jde hledat, atd.

## spousteni API

- [ ] zjistit jakym zpusobem lze mojolicious aplikaci spoustet
  - [hypnotoad](https://perlmaven.com/deploying-a-mojolicious-application)

## autentizace / autorizace

- [x] udelat research na optimalni metodu autentizace/autorizace

## logovani udalosti

- [ ] zjistit jake jsou moznosti

## sql

- [ ] vytvorit sql script pro aktualizaci schematu databaze
  - [ ] `personal_access_tokens.sql`
