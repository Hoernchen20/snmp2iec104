import { Navigate, Route, Routes } from "react-router";
import { useMe } from "./api/hooks";
import { Layout } from "./components/Layout";
import { ErrorBox, Loading } from "./components/ui";
import { DebugSocketProvider } from "./debug/context";
import { AccountPage, ForcedPasswordChange } from "./pages/Account";
import { ConfigPage } from "./pages/ConfigPage";
import { DebugPage } from "./pages/DebugPage";
import { EntityEditor } from "./pages/EntityEditor";
import { EntityList } from "./pages/EntityList";
import { LoginPage } from "./pages/LoginPage";
import { MibsPage } from "./pages/MibsPage";
import { StatusPage } from "./pages/StatusPage";
import { ToolsPage } from "./pages/ToolsPage";
import { UsersPage } from "./pages/UsersPage";

export function App() {
  const me = useMe();
  if (me.isPending) return <Loading />;
  if (me.isError) return <ErrorBox error={me.error} />;
  if (me.data === null) return <LoginPage />;
  if (me.data.must_change_password) return <ForcedPasswordChange me={me.data} />;
  const admin = me.data.role === "admin";
  return (
    <DebugSocketProvider>
      <Layout me={me.data}>
        <Routes>
          <Route path="/" element={<StatusPage />} />
          <Route path="/devices" element={<EntityList kind="devices" admin={admin} />} />
          <Route path="/devices/:name" element={<EntityEditor kind="devices" admin={admin} />} />
          <Route path="/profiles" element={<EntityList kind="profiles" admin={admin} />} />
          <Route path="/profiles/:name" element={<EntityEditor kind="profiles" admin={admin} />} />
          <Route path="/servers" element={<EntityList kind="servers" admin={admin} />} />
          <Route path="/servers/:name" element={<EntityEditor kind="servers" admin={admin} />} />
          <Route path="/config" element={<ConfigPage admin={admin} />} />
          <Route path="/debug" element={<DebugPage />} />
          <Route path="/tools" element={<ToolsPage />} />
          <Route path="/mibs" element={<MibsPage admin={admin} view="modules" />} />
          <Route path="/mibs/browse" element={<MibsPage admin={admin} view="browse" />} />
          <Route path="/users" element={admin ? <UsersPage me={me.data} /> : <Navigate to="/" />} />
          <Route path="/account" element={<AccountPage me={me.data} />} />
          <Route path="*" element={<Navigate to="/" />} />
        </Routes>
      </Layout>
    </DebugSocketProvider>
  );
}
