import { useParams, useNavigate } from "react-router-dom";
import { useQuery, useMutation, useQueryClient } from "@tanstack/react-query";
import { netsApi } from "@/api";
import type { Net, DhcpEntry } from "@/lib/types";
import { useServerContext } from "@/hooks/use-server-context";
import { useAuth } from "@/hooks/use-auth";
import { Button } from "@/components/ui/button";
import {
  Card,
  CardContent,
  CardHeader,
  CardTitle,
} from "@/components/ui/card";
import { Input } from "@/components/ui/input";
import { Label } from "@/components/ui/label";
import { Textarea } from "@/components/ui/textarea";
import {
  Select,
  SelectContent,
  SelectItem,
  SelectTrigger,
  SelectValue,
} from "@/components/ui/select";
import { Skeleton } from "@/components/ui/skeleton";
import {
  Dialog,
  DialogContent,
  DialogHeader,
  DialogTitle,
  DialogFooter,
  DialogDescription,
} from "@/components/ui/dialog";
import { ArrowLeft, Save, Loader2, Trash2, Pencil, X, Plus } from "lucide-react";
import { useState, useEffect } from "react";

const IP_POLICY_OPTIONS: Record<number, string> = {
  0: "Lowest free",
  10: "Highest free",
  20: "MAC based",
  30: "IPv4 based",
};

function booleanSelect(value: boolean | undefined) {
  return value === true ? "true" : value === false ? "false" : "";
}

function parseBoolean(value: string) {
  if (value === "true") return true;
  if (value === "false") return false;
  return undefined;
}

function Field({ label, value, mono }: { label: string; value: string; mono?: boolean }) {
  return (
    <div>
      <div className="text-muted-foreground text-xs">{label}</div>
      <div className={`font-medium text-sm ${mono ? "font-mono" : ""}`}>{value || "—"}</div>
    </div>
  );
}

export default function NetDetailPage() {
  const { netname } = useParams<{ netname: string }>();
  const navigate = useNavigate();
  const queryClient = useQueryClient();
  const { serverName } = useServerContext();
  const { isSuperuser } = useAuth();

  const [editing, setEditing] = useState(false);
  const [deleteOpen, setDeleteOpen] = useState(false);
  const [form, setForm] = useState<Partial<Net>>({});
  const [dhcpRows, setDhcpRows] = useState<DhcpEntry[]>([]);

  const decodedNetname = netname ? decodeURIComponent(netname) : "";

  const { data: net, isLoading } = useQuery({
    queryKey: ["nets", serverName, decodedNetname],
    queryFn: () => netsApi.get(serverName!, decodedNetname),
    enabled: !!serverName && !!decodedNetname,
  });

  useEffect(() => {
    if (net) {
      setForm({ ...net });
      setDhcpRows(net.dhcp_l ? [...net.dhcp_l] : []);
    }
  }, [net]);

  const updateMutation = useMutation({
    mutationFn: (data: Partial<Net>) => netsApi.update(serverName!, decodedNetname, data),
    onSuccess: () => {
      queryClient.invalidateQueries({ queryKey: ["nets", serverName] });
      queryClient.invalidateQueries({ queryKey: ["nets", serverName, decodedNetname] });
      setEditing(false);
    },
  });

  const deleteMutation = useMutation({
    mutationFn: () => netsApi.delete(serverName!, decodedNetname),
    onSuccess: () => {
      queryClient.invalidateQueries({ queryKey: ["nets", serverName] });
      navigate("/nets");
    },
  });

  if (!serverName) {
    return (
      <div className="flex flex-col items-center justify-center py-12">
        <h2 className="text-xl font-semibold">No Server Selected</h2>
        <Button className="mt-4" onClick={() => navigate("/")}>Go to Dashboard</Button>
      </div>
    );
  }

  if (isLoading) {
    return (
      <div className="space-y-4">
        <Skeleton className="h-8 w-48" />
        <Skeleton className="h-64 w-full" />
      </div>
    );
  }

  if (!net) {
    return (
      <div className="flex flex-col items-center justify-center py-12">
        <h2 className="text-xl font-semibold">Network not found</h2>
        <Button className="mt-4" onClick={() => navigate("/nets")}>Back to Networks</Button>
      </div>
    );
  }

  const isSubnet = form.subnet ?? false;
  const isDummy = form.dummy ?? false;
  const showVlanDhcp = !isDummy;
  const showSubnetFields = isSubnet;

  function handleSave() {
    const payload: Partial<Net> = {
      netname: form.netname,
      name: form.name,
      net: form.net,
      subnet: form.subnet,
      dummy: form.dummy,
      vlan: form.vlan,
      alevel: form.alevel,
      private_flag: form.private_flag,
      comment: form.comment,
    };

    if (isSubnet) {
      payload.range_start = form.range_start;
      payload.range_end = form.range_end;
      payload.ip_policy = form.ip_policy;
    }

    if (showVlanDhcp) {
      payload.no_dhcp = form.no_dhcp;
      payload.dhcp_l = dhcpRows.filter((r) => r.dhcp.trim() !== "");
    }

    updateMutation.mutate(payload);
  }

  function updateField<K extends keyof Net>(key: K, value: Net[K]) {
    setForm((prev) => {
      const next = { ...prev, [key]: value };
      if (key === "subnet" && !value) {
        next.dummy = false;
      }
      if (key === "dummy" && value) {
        next.vlan = undefined;
        next.no_dhcp = undefined;
      }
      return next;
    });
  }

  return (
    <div className="space-y-4">
      <div className="flex items-center justify-between">
        <div className="flex items-center gap-2">
          <Button variant="outline" size="icon" onClick={() => navigate("/nets")}>
            <ArrowLeft className="h-4 w-4" />
          </Button>
          <div>
            <h1 className="text-2xl font-bold tracking-tight">{net.netname}</h1>
            <p className="text-muted-foreground text-sm">{net.net}</p>
          </div>
        </div>
        <div className="flex items-center gap-2">
          {isSuperuser && !editing && (
            <>
              <Button variant="outline" onClick={() => setEditing(true)}>
                <Pencil className="mr-2 h-4 w-4" />
                Edit
              </Button>
              <Button variant="destructive" onClick={() => setDeleteOpen(true)}>
                <Trash2 className="mr-2 h-4 w-4" />
                Delete
              </Button>
            </>
          )}
          {editing && (
            <>
              <Button variant="outline" onClick={() => { setEditing(false); setForm({ ...net }); setDhcpRows(net.dhcp_l ? [...net.dhcp_l] : []); }}>
                Cancel
              </Button>
              <Button onClick={handleSave} disabled={updateMutation.isPending}>
                {updateMutation.isPending && <Loader2 className="mr-2 h-4 w-4 animate-spin" />}
                <Save className="mr-2 h-4 w-4" />
                Save
              </Button>
            </>
          )}
        </div>
      </div>

      <Card>
        <CardHeader>
          <CardTitle className="text-base">Network Details</CardTitle>
        </CardHeader>
        <CardContent>
          {editing ? (
            <div className="grid grid-cols-1 md:grid-cols-2 gap-6">
              <div className="space-y-4">
                <div className="grid gap-2">
                  <Label htmlFor="netname">Netname</Label>
                  <Input id="netname" value={form.netname || ""} onChange={(e) => updateField("netname", e.target.value)} />
                </div>
                <div className="grid gap-2">
                  <Label htmlFor="name">Description</Label>
                  <Input id="name" value={form.name || ""} onChange={(e) => updateField("name", e.target.value)} />
                </div>
                <div className="grid gap-2">
                  <Label htmlFor="net">Net (CIDR)</Label>
                  <Input id="net" value={form.net || ""} onChange={(e) => updateField("net", e.target.value)} />
                </div>
                <div className="grid gap-2">
                  <Label>Type</Label>
                  <Select value={booleanSelect(isSubnet)} onValueChange={(v) => updateField("subnet", parseBoolean(v) ?? false)}>
                    <SelectTrigger>
                      <SelectValue />
                    </SelectTrigger>
                    <SelectContent>
                      <SelectItem value="false">Net</SelectItem>
                      <SelectItem value="true">Subnet</SelectItem>
                    </SelectContent>
                  </Select>
                </div>
                {isSubnet && (
                  <div className="grid gap-2">
                    <Label>Virtual subnet</Label>
                    <Select value={booleanSelect(isDummy)} onValueChange={(v) => updateField("dummy", parseBoolean(v) ?? false)}>
                      <SelectTrigger>
                        <SelectValue />
                      </SelectTrigger>
                      <SelectContent>
                        <SelectItem value="false">No</SelectItem>
                        <SelectItem value="true">Yes</SelectItem>
                      </SelectContent>
                    </Select>
                  </div>
                )}
                <div className="grid gap-2">
                  <Label htmlFor="alevel">Authorization level</Label>
                  <Input id="alevel" type="number" value={form.alevel ?? ""} onChange={(e) => updateField("alevel", e.target.value === "" ? undefined : Number(e.target.value))} />
                </div>
                <div className="grid gap-2">
                  <Label>Private (hide from browser)</Label>
                  <Select value={booleanSelect(form.private_flag)} onValueChange={(v) => updateField("private_flag", parseBoolean(v))}>
                    <SelectTrigger>
                      <SelectValue />
                    </SelectTrigger>
                    <SelectContent>
                      <SelectItem value="true">Yes</SelectItem>
                      <SelectItem value="false">No</SelectItem>
                    </SelectContent>
                  </Select>
                </div>
                <div className="grid gap-2">
                  <Label htmlFor="comment">Comment</Label>
                  <Textarea id="comment" value={form.comment || ""} onChange={(e) => updateField("comment", e.target.value)} />
                </div>
              </div>

              <div className="space-y-4">
                {showVlanDhcp && (
                  <div className="grid gap-2">
                    <Label htmlFor="vlan">VLAN</Label>
                    <Input id="vlan" type="number" value={form.vlan ?? ""} onChange={(e) => updateField("vlan", e.target.value === "" ? undefined : Number(e.target.value))} />
                  </div>
                )}
                {showSubnetFields && (
                  <>
                    <div className="grid gap-2">
                      <Label htmlFor="range_start">Range start</Label>
                      <Input id="range_start" value={form.range_start || ""} onChange={(e) => updateField("range_start", e.target.value)} />
                    </div>
                    <div className="grid gap-2">
                      <Label htmlFor="range_end">Range end</Label>
                      <Input id="range_end" value={form.range_end || ""} onChange={(e) => updateField("range_end", e.target.value)} />
                    </div>
                    <div className="grid gap-2">
                      <Label>IP address assignment policy</Label>
                      <Select value={form.ip_policy === undefined ? "" : String(form.ip_policy)} onValueChange={(v) => updateField("ip_policy", Number(v))}>
                        <SelectTrigger>
                          <SelectValue />
                        </SelectTrigger>
                        <SelectContent>
                          {Object.entries(IP_POLICY_OPTIONS).map(([value, label]) => (
                            <SelectItem key={value} value={value}>
                              {label}
                            </SelectItem>
                          ))}
                        </SelectContent>
                      </Select>
                    </div>
                  </>
                )}
                {showVlanDhcp && (
                  <div className="grid gap-2">
                    <Label>DHCP</Label>
                    <Select value={form.no_dhcp === true ? "true" : "false"} onValueChange={(v) => updateField("no_dhcp", v === "true")}>
                      <SelectTrigger>
                        <SelectValue />
                      </SelectTrigger>
                      <SelectContent>
                        <SelectItem value="false">Enabled</SelectItem>
                        <SelectItem value="true">Disabled</SelectItem>
                      </SelectContent>
                    </Select>
                  </div>
                )}
                {showVlanDhcp && (
                  <div className="grid gap-2">
                    <Label>Net specific DHCP entries</Label>
                    <div className="rounded-md border">
                      <table className="w-full text-sm">
                        <thead>
                          <tr className="border-b text-muted-foreground">
                            <th className="text-left py-1 px-2 font-medium">DHCP</th>
                            <th className="text-left py-1 px-2 font-medium">Comment</th>
                            <th className="w-8" />
                          </tr>
                        </thead>
                        <tbody>
                          {dhcpRows.map((row, idx) => (
                            <tr key={idx} className="border-b last:border-0">
                              <td className="py-1 px-2">
                                <Input
                                  value={row.dhcp}
                                  onChange={(e) => {
                                    const next = [...dhcpRows];
                                    next[idx] = { ...next[idx], dhcp: e.target.value };
                                    setDhcpRows(next);
                                  }}
                                  className="h-7 text-xs"
                                />
                              </td>
                              <td className="py-1 px-2">
                                <Input
                                  value={row.comment || ""}
                                  onChange={(e) => {
                                    const next = [...dhcpRows];
                                    next[idx] = { ...next[idx], comment: e.target.value };
                                    setDhcpRows(next);
                                  }}
                                  className="h-7 text-xs"
                                />
                              </td>
                              <td className="py-1 px-2 text-right">
                                <Button
                                  type="button"
                                  variant="ghost"
                                  size="icon"
                                  className="h-6 w-6"
                                  onClick={() => setDhcpRows(dhcpRows.filter((_, i) => i !== idx))}
                                >
                                  <X className="h-3 w-3" />
                                </Button>
                              </td>
                            </tr>
                          ))}
                        </tbody>
                      </table>
                      <Button
                        type="button"
                        variant="outline"
                        size="sm"
                        className="m-2"
                        onClick={() => setDhcpRows([...dhcpRows, { dhcp: "", comment: "" }])}
                      >
                        <Plus className="mr-1 h-3 w-3" /> Add
                      </Button>
                    </div>
                  </div>
                )}
              </div>
            </div>
          ) : (
            <div className="grid grid-cols-1 md:grid-cols-2 gap-6">
              <div className="space-y-4">
                <Field label="Netname" value={net.netname} />
                <Field label="Description" value={net.name || ""} />
                <Field label="Net (CIDR)" value={net.net} mono />
                <Field label="Type" value={net.subnet ? "Subnet" : "Net"} />
                {net.subnet && <Field label="Virtual subnet" value={net.dummy ? "Yes" : "No"} />}
                <Field label="Authorization level" value={String(net.alevel ?? "")} />
                <Field label="Private" value={net.private_flag ? "Yes" : "No"} />
                <Field label="Comment" value={net.comment || ""} />
              </div>
              <div className="space-y-4">
                {!net.dummy && <Field label="VLAN" value={net.vlan_name || String(net.vlan ?? "")} />}
                {net.subnet && (
                  <>
                    <Field label="Range start" value={net.range_start || ""} />
                    <Field label="Range end" value={net.range_end || ""} />
                    <Field label="IP policy" value={net.ip_policy === undefined ? "" : IP_POLICY_OPTIONS[net.ip_policy] || String(net.ip_policy)} />
                  </>
                )}
                {!net.dummy && <Field label="DHCP" value={net.no_dhcp ? "Disabled" : "Enabled"} />}
                {net.dhcp_l && net.dhcp_l.length > 0 && (
                  <div>
                    <div className="text-muted-foreground text-xs">DHCP entries</div>
                    <div className="space-y-1 mt-1">
                      {net.dhcp_l.map((entry, idx) => (
                        <div key={idx} className="text-sm font-mono">
                          {entry.dhcp}
                          {entry.comment && <span className="text-muted-foreground ml-2">({entry.comment})</span>}
                        </div>
                      ))}
                    </div>
                  </div>
                )}
              </div>
            </div>
          )}
        </CardContent>
      </Card>

      {!editing && (
        <Card>
          <CardHeader>
            <CardTitle className="text-base">Record Info</CardTitle>
          </CardHeader>
          <CardContent>
            <div className="grid grid-cols-1 md:grid-cols-2 gap-6">
              <Field label="Record created" value={net.cdate ? new Date(net.cdate * 1000).toLocaleString() : "—"} />
              <Field label="Last modified" value={net.mdate ? new Date(net.mdate * 1000).toLocaleString() : "—"} />
            </div>
          </CardContent>
        </Card>
      )}

      <Dialog open={deleteOpen} onOpenChange={setDeleteOpen}>
        <DialogContent>
          <DialogHeader>
            <DialogTitle>Delete Network</DialogTitle>
            <DialogDescription>
              Are you sure you want to delete <strong>{net.netname}</strong>? This cannot be undone.
            </DialogDescription>
          </DialogHeader>
          <DialogFooter>
            <Button variant="outline" onClick={() => setDeleteOpen(false)}>
              Cancel
            </Button>
            <Button variant="destructive" onClick={() => deleteMutation.mutate()} disabled={deleteMutation.isPending}>
              {deleteMutation.isPending && <Loader2 className="mr-2 h-4 w-4 animate-spin" />}
              Delete
            </Button>
          </DialogFooter>
        </DialogContent>
      </Dialog>
    </div>
  );
}
