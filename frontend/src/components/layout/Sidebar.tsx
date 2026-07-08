import { Link, useLocation, useNavigate } from "react-router-dom";
import {
  Server,
  Globe,
  Monitor,
  Network,
  Users,
  FolderTree,
  Shield,
  KeyRound,
  Mail,
  Wifi,
  LayoutDashboard,
  LogOut,
  Moon,
  Sun,
} from "lucide-react";
import { useAuth } from "@/hooks/use-auth";
import { useServerContext } from "@/hooks/use-server-context";
import { Button } from "@/components/ui/button";
import { ScrollArea } from "@/components/ui/scroll-area";
import { Separator } from "@/components/ui/separator";
import { cn } from "@/lib/utils";
import { useState, useEffect } from "react";

const mainNav = [
  { to: "/", icon: LayoutDashboard, label: "Dashboard" },
  { to: "/servers", icon: Server, label: "Servers" },
];

const serverNav = [
  { to: "/zones", icon: Globe, label: "Zones" },
  { to: "/hosts", icon: Monitor, label: "Hosts" },
  { to: "/nets", icon: Network, label: "Networks" },
  { to: "/groups", icon: FolderTree, label: "Groups" },
  { to: "/vlans", icon: Wifi, label: "VLANs" },
  { to: "/acls", icon: Shield, label: "ACLs" },
  { to: "/keys", icon: KeyRound, label: "Keys" },
  { to: "/mx-templates", icon: Mail, label: "MX Templates" },
];

// Sub-categories of the Networks list, mirroring the legacy CGI menu
// (Networks / + Subnets / + All / + Free)
const netSubNav = [
  { mode: "", label: "Networks" },
  { mode: "sub", label: "+ Subnets" },
  { mode: "all", label: "+ All" },
  { mode: "free", label: "+ Free" },
];

const adminNav = [
  { to: "/users", icon: Users, label: "Users" },
];

export function Sidebar() {
  const location = useLocation();
  const navigate = useNavigate();
  const { user, logout, isSuperuser } = useAuth();
  const { serverId, serverName, zoneName } = useServerContext();
  const [dark, setDark] = useState(() =>
    document.documentElement.classList.contains("dark")
  );

  useEffect(() => {
    document.documentElement.classList.toggle("dark", dark);
    localStorage.setItem("sauron_theme", dark ? "dark" : "light");
  }, [dark]);

  // Initialize theme on mount
  useEffect(() => {
    const saved = localStorage.getItem("sauron_theme");
    if (saved === "dark") {
      setDark(true);
    } else if (saved === "light") {
      setDark(false);
    } else if (window.matchMedia("(prefers-color-scheme: dark)").matches) {
      setDark(true);
    }
  }, []);

  const handleLogout = () => {
    logout();
    navigate("/login");
  };

  return (
    <div className="flex h-full w-64 flex-col border-r bg-sidebar-background text-sidebar-foreground">
      {/* Header */}
      <div className="flex h-14 items-center border-b px-4">
        <Link to="/" className="flex items-center gap-2 font-semibold">
          <img src="/app/favicon.png" alt="" className="h-5 w-5" />
          <span>Sauron</span>
        </Link>
      </div>

      {/* Context info */}
      {serverId && (
        <div className="border-b px-4 py-2 text-xs">
          <div className="text-muted-foreground">Server</div>
          <div className="font-medium truncate">{serverName}</div>
          {zoneName && (
            <>
              <div className="text-muted-foreground mt-1">Zone</div>
              <div className="font-medium truncate">{zoneName}</div>
            </>
          )}
        </div>
      )}

      <ScrollArea className="flex-1">
        <div className="px-3 py-2">
          {/* Main nav */}
          <div className="space-y-1">
            {mainNav.map((item) => (
              <NavItem
                key={item.to}
                to={item.to}
                icon={item.icon}
                label={item.label}
                active={location.pathname === item.to}
              />
            ))}
          </div>

          {/* Server-scoped nav */}
          {serverId && (
            <>
              <Separator className="my-3" />
              <div className="mb-2 px-2 text-xs font-semibold text-muted-foreground uppercase tracking-wider">
                Manage
              </div>
              <div className="space-y-1">
                {serverNav.map((item) => (
                  <div key={item.to}>
                    <NavItem
                      to={item.to}
                      icon={item.icon}
                      label={item.label}
                      active={location.pathname.startsWith(item.to)}
                    />
                    {item.to === "/nets" && location.pathname.startsWith("/nets") && (
                      <div className="ml-6 mt-1 space-y-1 border-l pl-2">
                        {netSubNav.map((sub) => {
                          const listParam =
                            new URLSearchParams(location.search).get("list") ?? "";
                          const active =
                            location.pathname === "/nets" && listParam === sub.mode;
                          return (
                            <Link
                              key={sub.mode}
                              to={sub.mode ? `/nets?list=${sub.mode}` : "/nets"}
                              className={cn(
                                "block rounded-md px-2 py-1 text-xs font-medium transition-colors",
                                active
                                  ? "bg-sidebar-accent text-sidebar-accent-foreground"
                                  : "text-sidebar-foreground/60 hover:bg-sidebar-accent hover:text-sidebar-accent-foreground"
                              )}
                            >
                              {sub.label}
                            </Link>
                          );
                        })}
                      </div>
                    )}
                  </div>
                ))}
              </div>
            </>
          )}

          {/* Admin nav */}
          {isSuperuser && (
            <>
              <Separator className="my-3" />
              <div className="mb-2 px-2 text-xs font-semibold text-muted-foreground uppercase tracking-wider">
                Admin
              </div>
              <div className="space-y-1">
                {adminNav.map((item) => (
                  <NavItem
                    key={item.to}
                    to={item.to}
                    icon={item.icon}
                    label={item.label}
                    active={location.pathname.startsWith(item.to)}
                  />
                ))}
              </div>
            </>
          )}
        </div>
      </ScrollArea>

      {/* Footer */}
      <div className="border-t p-3">
        <div className="flex items-center justify-between">
          <div className="flex items-center gap-2 min-w-0">
            <div className="flex h-7 w-7 items-center justify-center rounded-full bg-primary text-primary-foreground text-xs font-medium">
              {user?.username?.charAt(0).toUpperCase()}
            </div>
            <div className="min-w-0">
              <div className="text-sm font-medium truncate">{user?.username}</div>
              <div className="text-xs text-muted-foreground truncate">
                {isSuperuser ? "Superuser" : "User"}
              </div>
            </div>
          </div>
          <div className="flex gap-1">
            <Button
              variant="ghost"
              size="icon"
              className="h-7 w-7"
              onClick={() => setDark(!dark)}
              title={dark ? "Light mode" : "Dark mode"}
            >
              {dark ? <Sun className="h-4 w-4" /> : <Moon className="h-4 w-4" />}
            </Button>
            <Button
              variant="ghost"
              size="icon"
              className="h-7 w-7"
              onClick={handleLogout}
              title="Logout"
            >
              <LogOut className="h-4 w-4" />
            </Button>
          </div>
        </div>
      </div>
    </div>
  );
}

function NavItem({
  to,
  icon: Icon,
  label,
  active,
}: {
  to: string;
  icon: React.ComponentType<{ className?: string }>;
  label: string;
  active: boolean;
}) {
  return (
    <Link
      to={to}
      className={cn(
        "flex items-center gap-3 rounded-md px-2 py-1.5 text-sm font-medium transition-colors",
        active
          ? "bg-sidebar-accent text-sidebar-accent-foreground"
          : "text-sidebar-foreground/70 hover:bg-sidebar-accent hover:text-sidebar-accent-foreground"
      )}
    >
      <Icon className="h-4 w-4 shrink-0" />
      {label}
    </Link>
  );
}
