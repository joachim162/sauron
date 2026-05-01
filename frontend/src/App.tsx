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
import GroupsPage from "@/pages/groups/GroupsPage";
import VlansPage from "@/pages/vlans/VlansPage";
import AclsPage from "@/pages/acls/AclsPage";
import KeysPage from "@/pages/keys/KeysPage";
import MxTemplatesPage from "@/pages/templates/MxTemplatesPage";
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
                <Route path="groups" element={<GroupsPage />} />
                <Route path="vlans" element={<VlansPage />} />
                <Route path="acls" element={<AclsPage />} />
                <Route path="keys" element={<KeysPage />} />
                <Route path="mx-templates" element={<MxTemplatesPage />} />
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
