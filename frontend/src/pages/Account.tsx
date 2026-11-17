import { useState, type FormEvent } from "react";
import { useChangePassword, useLogout } from "../api/hooks";
import type { Me } from "../api/types";
import { ErrorBox, Notice } from "../components/ui";

function PasswordForm({ onDone }: { onDone?: () => void }) {
  const change = useChangePassword();
  const [current, setCurrent] = useState("");
  const [next, setNext] = useState("");
  const [again, setAgain] = useState("");
  const mismatch = again !== "" && next !== again;
  const submit = (e: FormEvent) => {
    e.preventDefault();
    change.mutate(
      { current_password: current, new_password: next },
      {
        onSuccess: () => {
          setCurrent("");
          setNext("");
          setAgain("");
          onDone?.();
        },
      },
    );
  };
  return (
    <form onSubmit={submit}>
      <label className="stacked">
        Current password
        <input type="password" autoComplete="current-password" value={current} onChange={(e) => setCurrent(e.target.value)} />
      </label>
      <label className="stacked">
        New password <small className="hint">at least 8 characters</small>
        <input type="password" autoComplete="new-password" value={next} onChange={(e) => setNext(e.target.value)} />
      </label>
      <label className="stacked">
        Repeat new password
        <input type="password" autoComplete="new-password" value={again} onChange={(e) => setAgain(e.target.value)} />
      </label>
      {mismatch ? <div className="alert error">The new passwords differ</div> : null}
      <ErrorBox error={change.error} />
      {change.isSuccess ? <Notice kind="ok">Password changed. Your other sessions were ended.</Notice> : null}
      <button type="submit" className="primary" disabled={change.isPending || !current || !next || next !== again}>
        Change password
      </button>
    </form>
  );
}

/** Shown instead of the app while the password must be changed. */
export function ForcedPasswordChange({ me }: { me: Me }) {
  const logout = useLogout();
  return (
    <div className="center-page">
      <div className="card narrow">
        <h1>Change your password</h1>
        <p>
          The password of <strong>{me.name}</strong> was set by an administrator (or is the initial one) and must be
          changed before you continue.
        </p>
        <PasswordForm />
        <button type="button" className="link" onClick={() => logout.mutate()}>
          Log out
        </button>
      </div>
    </div>
  );
}

export function AccountPage({ me }: { me: Me }) {
  return (
    <div className="page narrow-page">
      <h1>Account</h1>
      <p>
        Logged in as <strong>{me.name}</strong> ({me.role}).
      </p>
      <section className="card">
        <h2>Change password</h2>
        <PasswordForm />
      </section>
    </div>
  );
}
