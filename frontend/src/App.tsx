import { BrowserRouter, Routes, Route, Navigate } from "react-router-dom";
import { QueryClient, QueryClientProvider } from "@tanstack/react-query";
import { ErrorBoundary } from "@/components/ErrorBoundary";
import { AuthProvider } from "@/hooks/use-auth";
import { ServerProvider } from "@/hooks/use-server-context";

import { AppLayout } from "@/components/layout/AppLayout";
import LoginPage from "@/pages/LoginPage";
import DashboardPage from "@/pages/DashboardPage";
import ServersPage from "@/pages/servers/ServersPage";
import ZonesPage from "@/pages/zones/ZonesPage";
import ZoneDetailPage from "@/pages/zones/ZoneDetailPage";
import HostsPage from "@/pages/hosts/HostsPage";
import HostDetailPage from "@/pages/hosts/HostDetailPage";
import NetsPage from "@/pages/nets/NetsPage";
import NetDetailPage from "@/pages/nets/NetDetailPage";
import GroupsPage from "@/pages/groups/GroupsPage";
import GroupDetailPage from "@/pages/groups/GroupDetailPage";
import VlansPage from "@/pages/vlans/VlansPage";
import VlanDetailPage from "@/pages/vlans/VlanDetailPage";
import AclsPage from "@/pages/acls/AclsPage";
import KeysPage from "@/pages/keys/KeysPage";
import TemplatesListPage from "@/pages/templates/TemplatesListPage";
import TemplatesDetailPage from "@/pages/templates/TemplatesDetailPage";
import UsersPage from "@/pages/users/UsersPage";

const queryClient = new QueryClient({
  defaultOptions: {
    queries: {
      retry: 1,
      refetchOnWindowFocus: false,
      staleTime: 30_000,
    },
  },
});

export default function App() {
  return (
    <QueryClientProvider client={queryClient}>
      <ErrorBoundary>
      <BrowserRouter basename="/app">
        <AuthProvider>
          <ServerProvider>
            <Routes>
              <Route path="/login" element={<LoginPage />} />
              <Route element={<AppLayout />}>
                <Route index element={<DashboardPage />} />
                <Route path="servers" element={<ServersPage />} />
                <Route path="zones" element={<ZonesPage />} />
                <Route path="zones/:name" element={<ZoneDetailPage />} />
                <Route path="hosts" element={<HostsPage />} />
                <Route path="hosts/:hostname" element={<HostDetailPage />} />
                <Route path="nets" element={<NetsPage />} />
                <Route path="nets/:netname" element={<NetDetailPage />} />
                <Route path="groups" element={<GroupsPage />} />
                <Route path="groups/:name" element={<GroupDetailPage />} />
                <Route path="vlans" element={<VlansPage />} />
                <Route path="vlans/:name" element={<VlanDetailPage />} />
                <Route path="acls" element={<AclsPage />} />
                <Route path="keys" element={<KeysPage />} />
                <Route path="templates" element={<Navigate to="/templates/mx" replace />} />
                <Route path="templates/mx" element={<TemplatesListPage kind="mx" />} />
                <Route path="templates/mx/:id" element={<TemplatesDetailPage kind="mx" />} />
                <Route path="templates/wks" element={<TemplatesListPage kind="wks" />} />
                <Route path="templates/wks/:id" element={<TemplatesDetailPage kind="wks" />} />
                <Route
                  path="templates/printer-classes"
                  element={<TemplatesListPage kind="printer-classes" />}
                />
                <Route
                  path="templates/printer-classes/:id"
                  element={<TemplatesDetailPage kind="printer-classes" />}
                />
                <Route path="templates/hinfo" element={<TemplatesListPage kind="hinfo" />} />
                <Route path="templates/hinfo/:id" element={<TemplatesDetailPage kind="hinfo" />} />
                <Route path="mx-templates" element={<Navigate to="/templates/mx" replace />} />
                <Route path="users" element={<UsersPage />} />
              </Route>
              <Route path="*" element={<Navigate to="/" replace />} />
            </Routes>
          </ServerProvider>
        </AuthProvider>
      </BrowserRouter>
      </ErrorBoundary>
    </QueryClientProvider>
  );
}
