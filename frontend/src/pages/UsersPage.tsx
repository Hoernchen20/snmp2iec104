import { useState, type FormEvent } from "react";
import { useDeleteUser, useSaveUser, useUsers } from "../api/hooks";
import type { Me, User } from "../api/types";
import { ConfirmButton, ErrorBox, Loading, Notice, formatDate } from "../components/ui";

export function UsersPage({ me }: { me: Me }) {
  const users = useUsers();
  return (
    <div className="page">
      <h1>Users</h1>
      <p className="muted">
        Viewers can read the configuration, the status and the live debug views; admins can change the configuration
        and manage users. A password set here must be changed by the user on the next login.
      </p>
      <ErrorBox error={users.error} />
      {users.isPending ? <Loading /> : null}
      {users.data ? (
        <table>
          <thead>
            <tr>
              <th>User</th>
              <th>Role</th>
              <th>Password</th>
              <th>Changed</th>
              <th />
            </tr>
          </thead>
          <tbody>
            {users.data.map((u) => (
              <UserRow key={u.name} user={u} self={u.name === me.name} />
            ))}
          </tbody>
        </table>
      ) : null}
      <NewUser />
    </div>
  );
}

function UserRow({ user, self }: { user: User; self: boolean }) {
  const save = useSaveUser();
  const remove = useDeleteUser();
  const [reset, setReset] = useState(false);
  const [password, setPassword] = useState("");
  return (
    <>
      <tr>
        <td>
          {user.name}
          {self ? <span className="muted"> (you)</span> : null}
        </td>
        <td>
          <select
            value={user.role}
            aria-label={`role of ${user.name}`}
            onChange={(e) => save.mutate({ name: user.name, value: { role: e.target.value as User["role"] } })}
          >
            <option value="admin">admin</option>
            <option value="viewer">viewer</option>
          </select>
        </td>
        <td>{user.must_change_password ? <span className="badge warn">must change</span> : <span className="muted">set</span>}</td>
        <td>{formatDate(user.updated_at)}</td>
        <td className="actions">
          {!self ? (
            <button type="button" className="link" onClick={() => setReset(!reset)}>
              reset password
            </button>
          ) : null}
          {!self ? (
            <ConfirmButton className="link" question={`Delete ${user.name}?`} onConfirm={() => remove.mutate(user.name)}>
              delete
            </ConfirmButton>
          ) : null}
        </td>
      </tr>
      {reset || save.error || remove.error ? (
        <tr className="sub-row">
          <td colSpan={5}>
            {reset ? (
              <form
                className="inline"
                onSubmit={(e) => {
                  e.preventDefault();
                  save.mutate(
                    { name: user.name, value: { password } },
                    {
                      onSuccess: () => {
                        setReset(false);
                        setPassword("");
                      },
                    },
                  );
                }}
              >
                <input
                  type="password"
                  autoComplete="new-password"
                  placeholder="new password (min. 8)"
                  value={password}
                  onChange={(e) => setPassword(e.target.value)}
                  aria-label={`new password for ${user.name}`}
                />
                <button type="submit" className="primary" disabled={password.length < 8}>
                  Set password
                </button>
                <span className="muted">ends the user's sessions; they must change it on the next login</span>
              </form>
            ) : null}
            <ErrorBox error={save.error ?? remove.error} />
          </td>
        </tr>
      ) : null}
    </>
  );
}

function NewUser() {
  const save = useSaveUser();
  const [name, setName] = useState("");
  const [role, setRole] = useState<"viewer" | "admin">("viewer");
  const [password, setPassword] = useState("");
  const [created, setCreated] = useState<string | null>(null);
  const submit = (e: FormEvent) => {
    e.preventDefault();
    save.mutate(
      { name, value: { role, password } },
      {
        onSuccess: () => {
          setCreated(name);
          setName("");
          setPassword("");
        },
      },
    );
  };
  return (
    <section className="card">
      <h2>New user</h2>
      <form className="inline" onSubmit={submit}>
        <input placeholder="name" value={name} onChange={(e) => setName(e.target.value)} aria-label="user name" />
        <select value={role} onChange={(e) => setRole(e.target.value as "viewer" | "admin")} aria-label="role">
          <option value="viewer">viewer</option>
          <option value="admin">admin</option>
        </select>
        <input
          type="password"
          autoComplete="new-password"
          placeholder="initial password (min. 8)"
          value={password}
          onChange={(e) => setPassword(e.target.value)}
          aria-label="initial password"
        />
        <button type="submit" className="primary" disabled={!name || password.length < 8 || save.isPending}>
          Create
        </button>
      </form>
      <ErrorBox error={save.error} title="Not created" />
      {created ? <Notice kind="ok">Created {created}; they must change the password on the first login.</Notice> : null}
    </section>
  );
}
