import { useState, type FormEvent } from "react";
import { useLogin } from "../api/hooks";
import { ErrorBox } from "../components/ui";

export function LoginPage() {
  const login = useLogin();
  const [username, setUsername] = useState("");
  const [password, setPassword] = useState("");
  const submit = (e: FormEvent) => {
    e.preventDefault();
    login.mutate({ username, password });
  };
  return (
    <div className="center-page">
      <form className="card narrow" onSubmit={submit}>
        <h1>snmp2iec104</h1>
        <label className="stacked">
          User name
          <input autoFocus autoComplete="username" value={username} onChange={(e) => setUsername(e.target.value)} />
        </label>
        <label className="stacked">
          Password
          <input
            type="password"
            autoComplete="current-password"
            value={password}
            onChange={(e) => setPassword(e.target.value)}
          />
        </label>
        <ErrorBox error={login.error} />
        <button type="submit" className="primary" disabled={login.isPending || !username || !password}>
          {login.isPending ? "Logging in…" : "Log in"}
        </button>
      </form>
    </div>
  );
}
