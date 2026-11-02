// Port of lib/screens/config/accounts_page.dart.
import { createMemo, createSignal, For, Match, onSettled, Show, Switch } from "solid-js";
import { asJsonObject } from "../../../core/rpc/json_fields";
import type { RpcLoginProvider } from "../../../core/rpc/results";
import { bootstrapModel } from "../../../core/session/machine_runtime";
import {
  type AccountsState,
  accountsStateFromJson,
  filterProviderRows,
  type ProviderRow,
  providerAccountsStoredOverridden,
  providerRowCredentials,
  providerRowInUse,
  providerRowPinned,
  providerRowSignedIn,
  providerRows,
  type StoredCredential,
} from "../../config/accounts";
import type { ConfigTarget } from "../../config/config_target";
import { t } from "../../i18n/i18n";
import { appLogger } from "../../utils/app_logger";
import { ActivityMark } from "../../widgets/activity_mark";
import { AppSearchField } from "../../widgets/app_search_field";
import { FilledButton, TextButton, TonalButton } from "../../widgets/button";
import { Icon } from "../../widgets/icon";
import * as Symbols from "../../widgets/symbols";
import { TextField } from "../../widgets/text_field";
import {
  ConfigBanner,
  ConfigError,
  ConfigHeader,
  ConfigTag,
  confirmAction,
  RefreshAction,
  runReporting,
} from "./config_widgets";
import { credentialStatus } from "./credential_status";
import { showRpcLogin } from "./login_dialogs";
import "./accounts_page.css";

/**
 * On a machine where no model works yet, the control process runs on this placeholder provider and `accounts.list`
 * names it as current; it is not a credential of the machine.
 */
const bootstrapProvider = bootstrapModel.split("/")[0];

/** The open row of the "Other provider" row; no provider id is empty. */
const otherRow = "";

/**
 * Every provider omp can use on the machine as one searchable list: sign-in providers, the providers of the available
 * models, the ones models.yml adds and the ones with stored credentials. A row opens in place to sign in, paste an API
 * key, pin an account or log out; the last row stores a key under any other provider id.
 *
 * The credentials come from the active session on this machine when there is one, because `active`, `sticky` and
 * `pinnable` describe that session; otherwise from the control process. Credentials are machine-wide.
 */
export function AccountsPage(props: { readonly target: ConfigTarget }) {
  const [accounts, setAccounts] = createSignal<AccountsState | undefined>(undefined);
  const [loginProviders, setLoginProviders] = createSignal<readonly RpcLoginProvider[]>([]);
  const [modelProviders, setModelProviders] = createSignal<ReadonlySet<string>>(new Set());
  const [error, setError] = createSignal<unknown>(undefined);
  const [loading, setLoading] = createSignal(true);
  const [query, setQuery] = createSignal("");
  const [open, setOpen] = createSignal<string | undefined>(undefined);
  let disposed = false;

  const rows = createMemo(() => {
    const state = accounts();
    if (state === undefined) return [];
    return filterProviderRows(
      providerRows({
        accounts: state,
        login: loginProviders(),
        modelProviders: modelProviders(),
        hidden: props.target.runtime.controlIsBootstrap ? bootstrapProvider : undefined,
      }),
      query(),
    );
  });
  const subtitle = () => {
    const project = props.target.projectSession();
    return project === undefined
      ? t.config.accounts.machineWide
      : t.config.accounts.sessionView({ path: project.cwd });
  };

  const load = async () => {
    // Also called after awaited work, when the page may be gone.
    if (disposed) return;
    setLoading(true);
    setError(undefined);
    try {
      const control = await props.target.control();
      const source = props.target.projectSession() ?? control;
      const state = accountsStateFromJson(asJsonObject(await source.companion.call("accounts.list"), "accounts.list"));
      const providers = await control.rpc.getLoginProviders();
      if (disposed) return;
      setAccounts(state);
      setLoginProviders(providers);
      // The model list is large over SSH; its providers may join the list after the page shows.
      void props.target.sessions.models(props.target.machine, control.rpc).then(
        (models) => {
          if (!disposed) setModelProviders(new Set(models.map((model) => model.provider)));
        },
        (failure: unknown) => appLogger.w("model list for the provider list failed", { error: failure }),
      );
    } catch (failure) {
      if (!disposed) setError(() => failure);
    } finally {
      if (!disposed) setLoading(false);
    }
  };

  onSettled(() => {
    void load();
    return () => {
      disposed = true;
    };
  });

  /** Credentials changed: the available models follow, and the lists here. */
  const changed = async () => {
    const control = await props.target.control();
    await props.target.sessions.models(props.target.machine, control.rpc, { refresh: true });
    await load();
  };

  const signIn = async (row: ProviderRow) => {
    const control = props.target.control();
    if (!(await runReporting(() => control)) || disposed) return;
    await showRpcLogin({ target: props.target, control: await control, providerId: row.id, providerName: row.name });
    if (!disposed) await runReporting(changed);
  };

  /**
   * The key goes to the machine as a 0600 file; the companion stores it in omp's credential store and deletes the
   * file.
   */
  const setKey = (provider: string, name: string, key: string) =>
    runReporting(
      async () => {
        const control = await props.target.control();
        const file = await props.target.uploadSecret(key.trim());
        try {
          await control.companion.call("accounts.setKey", { provider, keyFile: file });
        } finally {
          await props.target.discardSecret(file);
        }
        await changed();
      },
      { done: t.config.accounts.keyStored({ provider: name }), secret: true },
    );

  const logout = async (row: ProviderRow, credential: StoredCredential) => {
    const confirmed = await confirmAction({
      title: t.config.accounts.logoutTitle({ account: credential.label }),
      body: t.config.accounts.logoutBody({ provider: row.name }),
      action: t.config.accounts.logout,
    });
    if (!confirmed || disposed) return;
    await runReporting(async () => {
      const control = await props.target.control();
      await control.companion.call("accounts.logout", { provider: row.id, credentialId: credential.credentialId });
      await changed();
    });
  };

  const pin = async (credential: StoredCredential) => {
    const session = props.target.projectSession();
    if (session === undefined) return;
    await runReporting(
      async () => {
        await session.companion.call("accounts.pin", { credentialId: credential.credentialId });
        await load();
      },
      { done: t.config.accounts.pinned },
    );
  };

  return (
    <div class="config-page-body">
      <ConfigHeader
        title={t.config.sections.accounts}
        subtitle={subtitle()}
        actions={<RefreshAction loading={loading()} onPressed={() => void load()} />}
      />
      <Show when={props.target.runtime.controlIsBootstrap}>
        <div class="accounts-page-bar">
          <ConfigBanner text={t.config.accounts.bootstrap} error />
        </div>
      </Show>
      <div class="accounts-page-bar">
        <AppSearchField hint={t.config.accounts.search} onChanged={setQuery} />
      </div>
      <Switch
        fallback={
          // The rows' fill lines up with the search field above.
          <div class="config-list">
            <Show when={rows().length === 0}>
              <p class="accounts-page-empty">{t.config.accounts.noMatches}</p>
            </Show>
            <For each={rows()} keyed={(row) => row.id}>
              {(row) => (
                <ProviderTile
                  row={row()}
                  open={open() === row().id}
                  remote={!props.target.isThisComputer}
                  canPin={props.target.projectSession() !== undefined}
                  onToggle={() => setOpen(open() === row().id ? undefined : row().id)}
                  onSignIn={() => void signIn(row())}
                  onSaveKey={(key) => setKey(row().id, row().name, key)}
                  onLogout={(credential) => void logout(row(), credential)}
                  onPin={(credential) => void pin(credential)}
                />
              )}
            </For>
            <OtherProviderTile
              open={open() === otherRow}
              initialId={rows().length === 0 ? query().trim() : ""}
              onToggle={() => setOpen(open() === otherRow ? undefined : otherRow)}
              onSaveKey={async (provider, key) => {
                const saved = await setKey(provider, provider, key);
                if (saved && !disposed) setOpen(provider);
                return saved;
              }}
            />
          </div>
        }
      >
        <Match when={accounts() === undefined && error() !== undefined}>
          <div class="accounts-page-center">
            <ConfigError error={error()} onRetry={() => void load()} />
          </div>
        </Match>
        <Match when={accounts() === undefined}>
          <div class="accounts-page-center">
            <ActivityMark size={20} />
          </div>
        </Match>
      </Switch>
    </div>
  );
}

/**
 * One provider: name, kind and status on one dense line; open, the working source in plain words, stored credentials,
 * sign-in and an API key field.
 */
function ProviderTile(props: {
  readonly row: ProviderRow;
  readonly open: boolean;
  readonly remote: boolean;
  readonly canPin: boolean;
  readonly onToggle: () => void;
  readonly onSignIn: () => void;
  readonly onSaveKey: (key: string) => Promise<boolean>;
  readonly onLogout: (credential: StoredCredential) => void;
  readonly onPin: (credential: StoredCredential) => void;
}) {
  return (
    <div class={["accounts-page-tile", { "accounts-page-tile-open": props.open }]}>
      <button type="button" data-ripple class="accounts-page-header" onClick={() => props.onToggle()}>
        <span class="accounts-page-names">
          <span class="accounts-page-name">{props.row.name}</span>
          <Show when={props.row.name !== props.row.id}>
            <span class="accounts-page-id">{props.row.id}</span>
          </Show>
        </span>
        <span class="accounts-page-tags">
          <Show when={providerRowInUse(props.row)}>
            <ConfigTag label={t.config.accounts.active} color="var(--on-surface)" />
          </Show>
          <Show when={providerRowPinned(props.row)}>
            <ConfigTag label={t.config.accounts.sticky} color="var(--on-surface)" />
          </Show>
          <Show when={providerRowSignedIn(props.row)}>
            <ConfigTag label={t.config.accounts.signedIn} color="var(--success)" />
          </Show>
          <ConfigTag label={t.config.accounts.kind[props.row.kind]} />
        </span>
        <Icon icon={props.open ? Symbols.expand_less : Symbols.expand_more} size={18} class="accounts-page-chevron" />
      </button>
      <Show when={props.open}>
        <div class="accounts-page-details">
          <p class="config-muted">{sourceText(props.row)}</p>
          <Show
            when={
              props.row.accounts !== undefined && providerAccountsStoredOverridden(props.row.accounts)
                ? props.row.accounts
                : undefined
            }
          >
            {(accounts) => (
              <p class="accounts-page-overridden">
                {accounts().sourceKind === "env"
                  ? t.config.accounts.overridden.env({ name: accounts().envVar ?? "?" })
                  : accounts().sourceKind === "runtime"
                    ? t.config.accounts.overridden.runtime
                    : t.config.accounts.overridden.config}
              </p>
            )}
          </Show>
          <For each={providerRowCredentials(props.row)}>
            {(credential) => (
              <CredentialRow
                credential={credential}
                canPin={props.canPin}
                onLogout={props.onLogout}
                onPin={props.onPin}
              />
            )}
          </For>
          <Show when={props.row.canSignIn}>
            <div class="accounts-page-sign-in">
              <FilledButton icon={Symbols.login} onClick={() => props.onSignIn()}>
                {t.config.accounts.signIn}
              </FilledButton>
              <p class="config-muted">{props.remote ? t.config.accounts.oauthRemote : t.config.accounts.oauthLocal}</p>
            </div>
          </Show>
          <KeyField onSave={props.onSaveKey} />
        </div>
      </Show>
    </div>
  );
}

/** A key for a provider id the list does not show; open, the id and the key. */
function OtherProviderTile(props: {
  readonly open: boolean;
  /** Fills the id when the row opens: the search text that matched no provider. */
  readonly initialId: string;
  readonly onToggle: () => void;
  readonly onSaveKey: (provider: string, key: string) => Promise<boolean>;
}) {
  const [id, setId] = createSignal("");
  return (
    <div class={["accounts-page-tile", { "accounts-page-tile-open": props.open }]}>
      <button
        type="button"
        data-ripple
        class="accounts-page-header"
        onClick={() => {
          if (!props.open && props.initialId !== "") setId(props.initialId);
          props.onToggle();
        }}
      >
        <span class="accounts-page-name accounts-page-other">{t.config.accounts.other}</span>
        <Icon icon={props.open ? Symbols.expand_less : Symbols.expand_more} size={18} class="accounts-page-chevron" />
      </button>
      <Show when={props.open}>
        <div class="accounts-page-details accounts-page-other-details">
          <p class="config-muted">{t.config.accounts.otherNote}</p>
          <TextField class="accounts-page-other-id" value={id()} onInput={setId} hint={t.config.accounts.otherId} />
          <KeyField ready={id().trim() !== ""} onSave={(key) => props.onSaveKey(id().trim(), key)} />
        </div>
      </Show>
    </div>
  );
}

/** What authenticates [row] now, in plain words. */
function sourceText(row: ProviderRow): string {
  const source = t.config.accounts.source;
  switch (row.accounts?.sourceKind) {
    case "runtime":
      return source.runtime;
    case "config":
      return source.config;
    case "oauth":
      return source.oauth;
    case "apiKey":
      return source.apiKey;
    case "env":
      return source.env({ name: row.accounts?.envVar ?? "?" });
    case undefined:
      if (row.authenticated) return source.working;
      return row.kind === "account" ? source.none : source.noKey;
  }
}

function CredentialRow(props: {
  readonly credential: StoredCredential;
  readonly canPin: boolean;
  readonly onLogout: (credential: StoredCredential) => void;
  readonly onPin: (credential: StoredCredential) => void;
}) {
  return (
    <div class="accounts-page-credential">
      <Icon
        icon={props.credential.oauth ? Symbols.account_circle : Symbols.vpn_key}
        size={18}
        class="accounts-page-credential-icon"
      />
      <div class="accounts-page-credential-text">
        <p>{props.credential.label}</p>
        <Show when={credentialStatus(props.credential)}>{(status) => <p class="config-muted">{status()}</p>}</Show>
      </div>
      <Show when={props.credential.pinnable && props.canPin && !props.credential.sticky}>
        <TextButton onClick={() => props.onPin(props.credential)}>{t.config.accounts.pin}</TextButton>
      </Show>
      <TextButton onClick={() => props.onLogout(props.credential)}>{t.config.accounts.logout}</TextButton>
    </div>
  );
}

/** A pasted API key for the row's provider and its save button, one control height. */
function KeyField(props: {
  readonly onSave: (key: string) => Promise<boolean>;
  /** Everything besides the key is filled in; true when left out. */
  readonly ready?: boolean;
}) {
  const [key, setKey] = createSignal("");
  const [saving, setSaving] = createSignal(false);
  let disposed = false;
  onSettled(() => () => {
    disposed = true;
  });

  const save = async () => {
    if (key().trim() === "" || props.ready === false || saving()) return;
    setSaving(true);
    const saved = await props.onSave(key());
    if (disposed) return;
    if (saved) setKey("");
    setSaving(false);
  };

  return (
    <div class="accounts-page-key-field">
      <TextField
        class="accounts-page-key-input"
        type="password"
        value={key()}
        onInput={setKey}
        onSubmit={() => void save()}
        hint={t.config.accounts.keyHint}
      />
      <TonalButton disabled={saving() || props.ready === false || key().trim() === ""} onClick={() => void save()}>
        <Show when={saving()} fallback={t.config.accounts.saveKey}>
          <ActivityMark size={16} />
        </Show>
      </TonalButton>
    </div>
  );
}
