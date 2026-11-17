import { useMutation, useQuery, useQueryClient } from "@tanstack/react-query";
import { del, enc, get, post, put } from "./client";
import type {
  AuditEntry,
  Config,
  EntityKind,
  EntityMap,
  Me,
  Status,
  User,
  UserInput,
  Validation,
  Varbind,
  Version,
} from "./types";
import type { JsonSchema } from "../schema/types";

// --- session ------------------------------------------------------------------

export function useMe() {
  return useQuery({
    queryKey: ["me"],
    queryFn: async () => {
      try {
        return await get<Me>("me");
      } catch (e) {
        if ((e as { status?: number }).status === 401) return null;
        throw e;
      }
    },
    staleTime: Infinity,
    retry: false,
  });
}

export function useLogin() {
  const qc = useQueryClient();
  return useMutation({
    mutationFn: (v: { username: string; password: string }) => post<Me>("login", v),
    onSuccess: (me) => {
      qc.clear();
      qc.setQueryData(["me"], me);
    },
  });
}

export function useLogout() {
  const qc = useQueryClient();
  return useMutation({
    mutationFn: () => post<void>("logout"),
    onSettled: () => {
      qc.clear();
      qc.setQueryData(["me"], null);
    },
  });
}

export function useChangePassword() {
  const qc = useQueryClient();
  return useMutation({
    mutationFn: (v: { current_password: string; new_password: string }) => post<Me>("me/password", v),
    onSuccess: (me) => qc.setQueryData(["me"], me),
  });
}

// --- API description (schemas for the entity forms) ------------------------

interface OpenApi {
  components: { schemas: Record<string, JsonSchema> };
}

export function useSchemas() {
  return useQuery({
    queryKey: ["openapi"],
    queryFn: () => get<OpenApi>("openapi.json"),
    staleTime: Infinity,
    select: (d) => d.components.schemas,
  });
}

// --- entities (staged configuration) -----------------------------------------

export function useEntities<K extends EntityKind>(kind: K) {
  return useQuery({ queryKey: ["entities", kind], queryFn: () => get<EntityMap[K][]>(kind) });
}

export function useEntity<K extends EntityKind>(kind: K, name: string | undefined) {
  return useQuery({
    queryKey: ["entity", kind, name],
    queryFn: () => get<EntityMap[K]>(`${kind}/${enc(name!)}`),
    enabled: name !== undefined,
  });
}

function invalidateConfig(qc: ReturnType<typeof useQueryClient>) {
  return Promise.all([
    qc.invalidateQueries({ queryKey: ["entities"] }),
    qc.invalidateQueries({ queryKey: ["entity"] }),
    qc.invalidateQueries({ queryKey: ["staged"] }),
    qc.invalidateQueries({ queryKey: ["status"] }),
    qc.invalidateQueries({ queryKey: ["audit"] }),
  ]);
}

export function useSaveEntity(kind: EntityKind) {
  const qc = useQueryClient();
  return useMutation({
    mutationFn: ({ name, value }: { name: string; value: unknown }) => put<unknown>(`${kind}/${enc(name)}`, value),
    onSuccess: () => invalidateConfig(qc),
  });
}

export function useDeleteEntity(kind: EntityKind) {
  const qc = useQueryClient();
  return useMutation({
    mutationFn: (name: string) => del(`${kind}/${enc(name)}`),
    onSuccess: () => invalidateConfig(qc),
  });
}

// --- configuration -----------------------------------------------------------------

export function useStaged() {
  return useQuery({
    queryKey: ["staged"],
    queryFn: () => get<{ config: Config; has_changes: boolean }>("config/staged"),
  });
}

export function useActive() {
  return useQuery({
    queryKey: ["active"],
    queryFn: async () => {
      try {
        return await get<{ vsn: number; config: Config }>("config/active");
      } catch (e) {
        if ((e as { status?: number }).status === 404) return null;
        throw e;
      }
    },
  });
}

export function useValidate() {
  return useMutation({ mutationFn: () => post<Validation>("config/validate") });
}

export function useActivate() {
  const qc = useQueryClient();
  return useMutation({
    mutationFn: (comment: string) => post<{ vsn: number }>("config/activate", { comment }),
    onSuccess: () =>
      Promise.all([
        invalidateConfig(qc),
        qc.invalidateQueries({ queryKey: ["active"] }),
        qc.invalidateQueries({ queryKey: ["versions"] }),
      ]),
  });
}

export function useRevert() {
  const qc = useQueryClient();
  return useMutation({ mutationFn: () => post<void>("config/revert"), onSuccess: () => invalidateConfig(qc) });
}

export function useImport() {
  const qc = useQueryClient();
  return useMutation({
    mutationFn: (config: unknown) => post<void>("config/import", config),
    onSuccess: () => invalidateConfig(qc),
  });
}

export function useVersions() {
  return useQuery({ queryKey: ["versions"], queryFn: () => get<Version[]>("config/versions") });
}

export function useVersion(vsn: number | undefined) {
  return useQuery({
    queryKey: ["version", vsn],
    queryFn: () => get<{ vsn: number; config: Config }>(`config/versions/${vsn}`),
    enabled: vsn !== undefined,
    staleTime: Infinity,
  });
}

export function useRestore() {
  const qc = useQueryClient();
  return useMutation({
    mutationFn: (vsn: number) => post<void>(`config/versions/${vsn}/restore`),
    onSuccess: () => invalidateConfig(qc),
  });
}

export function useAudit(limit: number) {
  return useQuery({ queryKey: ["audit", limit], queryFn: () => get<AuditEntry[]>(`config/audit?limit=${limit}`) });
}

// --- status ----------------------------------------------------------------------

export function useStatus(refetchInterval = 5000) {
  return useQuery({ queryKey: ["status"], queryFn: () => get<Status>("status"), refetchInterval });
}

// --- users ---------------------------------------------------------------------------

export function useUsers() {
  return useQuery({ queryKey: ["users"], queryFn: () => get<User[]>("users") });
}

export function useSaveUser() {
  const qc = useQueryClient();
  return useMutation({
    mutationFn: ({ name, value }: { name: string; value: UserInput }) => put<User>(`users/${enc(name)}`, value),
    onSuccess: () =>
      Promise.all([
        qc.invalidateQueries({ queryKey: ["users"] }),
        qc.invalidateQueries({ queryKey: ["me"] }),
        qc.invalidateQueries({ queryKey: ["audit"] }),
      ]),
  });
}

export function useDeleteUser() {
  const qc = useQueryClient();
  return useMutation({
    mutationFn: (name: string) => del(`users/${enc(name)}`),
    onSuccess: () => qc.invalidateQueries({ queryKey: ["users"] }),
  });
}

// --- tools -------------------------------------------------------------------------------

export function useSnmpGet() {
  return useMutation({
    mutationFn: (v: { device: string; oids: string[] }) => post<{ varbinds: Varbind[] }>("tools/snmp/get", v),
  });
}

export function useSnmpWalk() {
  return useMutation({
    mutationFn: (v: { device: string; oid: string; max: number }) =>
      post<{ varbinds: Varbind[]; truncated: boolean }>("tools/snmp/walk", v),
  });
}
