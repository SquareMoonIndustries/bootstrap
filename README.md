# bootstrap

Entrypoint for Square Moon workstation setup. Public because a brand-new
machine has no credentials yet; everything it fetches afterwards is private.

```bash
curl -fsSL https://raw.githubusercontent.com/SquareMoonIndustries/bootstrap/master/mac.sh -o /tmp/sm-setup.sh
bash /tmp/sm-setup.sh developer
```

Swap `developer` for `consultant` if you only need the shared skills.

Download-then-run, not `curl | bash`: on a machine that still needs Homebrew
or a GitHub login, those steps have to prompt you, and a piped script has the
pipe as its stdin.
