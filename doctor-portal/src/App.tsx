import { useEffect, useMemo, useState } from "react";
import type { FormEvent, ReactNode } from "react";
import {
  Activity,
  CalendarDays,
  ChevronRight,
  ClipboardList,
  Clock3,
  HeartPulse,
  LayoutDashboard,
  LogOut,
  Menu,
  Search,
  ShieldCheck,
  UsersRound,
  X,
} from "lucide-react";
import type { Session } from "@supabase/supabase-js";
import {
  apiGet,
  configurationError,
  supabase,
  type DoctorAppointment,
  type DoctorProfile,
  type PatientDetail,
  type PatientSummary,
} from "./api";

type Section = "overview" | "patients" | "appointments";

function App() {
  const [session, setSession] = useState<Session | null>(null);
  const [authLoading, setAuthLoading] = useState(Boolean(supabase));
  const [authError, setAuthError] = useState("");

  useEffect(() => {
    if (!supabase) return;
    let alive = true;
    void supabase.auth.getSession().then(({ data, error }) => {
      if (!alive) return;
      if (error) setAuthError(error.message);
      setSession(data.session);
      setAuthLoading(false);
    });
    const { data } = supabase.auth.onAuthStateChange((_event, nextSession) => {
      setSession(nextSession);
      setAuthError("");
      setAuthLoading(false);
    });
    return () => {
      alive = false;
      data.subscription.unsubscribe();
    };
  }, []);

  if (configurationError) return <NoticePage title="Portal setup needed" message={configurationError} />;
  if (authLoading) return <LoadingPage />;
  if (!session) {
    return (
      <SignInPage
        error={authError}
        onSignIn={async (email, password) => {
          const { error } = await supabase!.auth.signInWithPassword({ email, password });
          if (error) setAuthError(error.message);
        }}
      />
    );
  }
  return (
    <Portal
      session={session}
      onSignOut={async () => {
        const { error } = await supabase!.auth.signOut();
        if (error) throw error;
      }}
    />
  );
}

function Portal({ session, onSignOut }: { session: Session; onSignOut: () => Promise<void> }) {
  const [section, setSection] = useState<Section>("overview");
  const [profile, setProfile] = useState<DoctorProfile | null>(null);
  const [patients, setPatients] = useState<PatientSummary[]>([]);
  const [appointments, setAppointments] = useState<DoctorAppointment[]>([]);
  const [detail, setDetail] = useState<PatientDetail | null>(null);
  const [selectedPatientId, setSelectedPatientId] = useState<string | null>(null);
  const [query, setQuery] = useState("");
  const [error, setError] = useState("");
  const [loading, setLoading] = useState(true);
  const [detailLoading, setDetailLoading] = useState(false);
  const [mobileMenu, setMobileMenu] = useState(false);
  const [reloadKey, setReloadKey] = useState(0);

  useEffect(() => {
    let alive = true;
    setLoading(true);
    setError("");
    void Promise.all([
      apiGet<DoctorProfile>("/doctor/me", session),
      apiGet<PatientSummary[]>("/doctor/patients", session),
      apiGet<DoctorAppointment[]>("/doctor/appointments", session),
    ])
      .then(([doctor, patientRows, appointmentRows]) => {
        if (!alive) return;
        setProfile(doctor);
        setPatients(patientRows);
        setAppointments(appointmentRows);
        setSelectedPatientId((current) =>
          current && patientRows.some((patient) => patient.user_id === current)
            ? current
            : patientRows[0]?.user_id ?? null,
        );
      })
      .catch((cause: unknown) => {
        if (!alive) return;
        setError(
          cause instanceof Error
            ? cause.message
            : "Could not load the doctor workspace. Try again.",
        );
      })
      .finally(() => {
        if (alive) setLoading(false);
      });
    return () => {
      alive = false;
    };
  }, [session, reloadKey]);

  useEffect(() => {
    if (!selectedPatientId) {
      setDetail(null);
      return;
    }
    let alive = true;
    setDetailLoading(true);
    void apiGet<PatientDetail>(`/doctor/patients/${selectedPatientId}`, session)
      .then((patient) => {
        if (alive) setDetail(patient);
      })
      .catch((cause: unknown) => {
        if (alive) {
          setDetail(null);
          setError(cause instanceof Error ? cause.message : "Could not load this patient.");
        }
      })
      .finally(() => {
        if (alive) setDetailLoading(false);
      });
    return () => {
      alive = false;
    };
  }, [selectedPatientId, session]);

  const filteredPatients = useMemo(() => {
    const normalized = query.trim().toLowerCase();
    if (!normalized) return patients;
    return patients.filter((patient) =>
      `${patient.full_name} ${patient.phone ?? ""}`.toLowerCase().includes(normalized),
    );
  }, [patients, query]);
  const upcomingAppointments = appointments.filter(
    (appointment) =>
      new Date(appointment.ends_at).getTime() >= Date.now() &&
      !["cancelled", "rescheduled"].includes(appointment.status),
  );
  const recentSymptomPatients = patients.filter(
    (patient) =>
      patient.latest_symptom_at &&
      Date.parse(patient.latest_symptom_at) >= Date.now() - 30 * 24 * 60 * 60 * 1000,
  ).length;

  const navigate = (next: Section) => {
    setSection(next);
    setMobileMenu(false);
  };

  return (
    <div className={`portal ${mobileMenu ? "menu-open" : ""}`}>
      <aside className="sidebar">
        <div className="brand">
          <div className="brand-mark"><HeartPulse size={22} strokeWidth={2.5} /></div>
          <div><strong>smartmed</strong><span>CARE PORTAL</span></div>
          <button className="icon-button mobile-close" onClick={() => setMobileMenu(false)} aria-label="Close menu"><X size={19} /></button>
        </div>
        <div className="clinic-label">WORKSPACE</div>
        <nav className="side-nav" aria-label="Main navigation">
          <NavButton active={section === "overview"} icon={<LayoutDashboard size={18} />} label="Overview" onClick={() => navigate("overview")} />
          <NavButton active={section === "patients"} icon={<UsersRound size={18} />} label="My patients" count={patients.length} onClick={() => navigate("patients")} />
          <NavButton active={section === "appointments"} icon={<CalendarDays size={18} />} label="Appointments" count={upcomingAppointments.length} onClick={() => navigate("appointments")} />
        </nav>
        <div className="sidebar-footer">
          <div className="privacy-note"><ShieldCheck size={17} /><span>Protected clinical workspace</span></div>
          <button
            className="doctor-switcher"
            aria-label="Sign out"
            title="Sign out"
            onClick={() => {
              void onSignOut().catch((cause: unknown) =>
                setError(cause instanceof Error ? cause.message : "Could not sign out."),
              );
            }}
          >
            <Avatar name={profile?.full_name ?? session.user.email ?? "Doctor"} />
            <span className="doctor-identity"><strong>{profile?.full_name ?? "Doctor"}</strong><small>{profile?.specialization ?? "Verified clinician"}</small></span>
            <LogOut size={16} className="signout-icon" />
          </button>
        </div>
      </aside>
      <div className="portal-main">
        <header className="topbar">
          <button className="icon-button menu-trigger" onClick={() => setMobileMenu(true)} aria-label="Open menu"><Menu size={20} /></button>
          <div className="breadcrumb"><span>Workspace</span><ChevronRight size={14} /><strong>{sectionTitle(section)}</strong></div>
          <div className="topbar-right">
            <span className="today-label"><span className="live-dot" />Secure session</span>
            <Avatar name={profile?.full_name ?? "Doctor"} small />
          </div>
        </header>
        <main className="content">
          <div className="page-heading">
            <div>
              <div className="eyebrow">{formatDate(new Date().toISOString())}</div>
              <h1>{section === "overview" ? `Good day${profile ? `, Dr. ${profile.full_name.split(" ").at(-1)}` : ""}` : sectionTitle(section)}</h1>
              <p>{section === "overview" ? "Here’s what’s happening with your patients today." : sectionDescription(section)}</p>
            </div>
            <button className="secondary-button" onClick={() => setReloadKey((key) => key + 1)} disabled={loading}>
              <Activity size={16} /> Refresh
            </button>
          </div>
          {error && <div className="error-banner" role="alert"><span>{error}</span><button onClick={() => setError("")} aria-label="Dismiss error"><X size={16} /></button></div>}
          {loading ? <LoadingInline /> : (
            <>
              {section === "overview" && (
                <Overview
                  patientCount={patients.length}
                  appointmentCount={upcomingAppointments.length}
                  symptomCount={recentSymptomPatients}
                  appointments={upcomingAppointments}
                  patients={patients.slice(0, 5)}
                  onOpenAppointments={() => navigate("appointments")}
                  onOpenPatients={() => navigate("patients")}
                  onSelectPatient={(id) => { setSelectedPatientId(id); navigate("patients"); }}
                />
              )}
              {section === "patients" && (
                <PatientsPage
                  patients={filteredPatients}
                  selectedId={selectedPatientId}
                  detail={detail}
                  detailLoading={detailLoading}
                  query={query}
                  onQuery={setQuery}
                  onSelect={setSelectedPatientId}
                />
              )}
              {section === "appointments" && <AppointmentsPage appointments={appointments} />}
            </>
          )}
          <footer className="content-footer"><span>SmartMed Doctor Portal</span><span>Patient records are available only for active care-team assignments.</span></footer>
        </main>
      </div>
      {mobileMenu && <button className="mobile-scrim" aria-label="Close navigation" onClick={() => setMobileMenu(false)} />}
    </div>
  );
}

function Overview({
  patientCount,
  appointmentCount,
  symptomCount,
  appointments,
  patients,
  onOpenAppointments,
  onOpenPatients,
  onSelectPatient,
}: {
  patientCount: number;
  appointmentCount: number;
  symptomCount: number;
  appointments: DoctorAppointment[];
  patients: PatientSummary[];
  onOpenAppointments: () => void;
  onOpenPatients: () => void;
  onSelectPatient: (id: string) => void;
}) {
  return (
    <>
      <div className="stats-grid">
        <StatCard icon={<UsersRound size={19} />} label="Active patients" value={patientCount} note="In your care team" tone="blue" />
        <StatCard icon={<CalendarDays size={19} />} label="Upcoming visits" value={appointmentCount} note="Scheduled appointments" tone="violet" />
        <StatCard icon={<HeartPulse size={19} />} label="Recent symptom activity" value={symptomCount} note="Patients reporting in 30 days" tone="rose" />
      </div>
      <div className="dashboard-grid">
        <section className="panel appointments-panel">
          <PanelHeading title="Upcoming appointments" subtitle="Your next scheduled visits" action="View schedule" onAction={onOpenAppointments} />
          {appointments.length ? (
            <div className="appointment-list">
              {appointments.slice(0, 4).map((appointment) => <AppointmentRow key={appointment.id} appointment={appointment} />)}
            </div>
          ) : <EmptyState title="No upcoming visits" detail="Appointments for your assigned patients will appear here." />}
        </section>
        <section className="panel patient-panel">
          <PanelHeading title="Your patients" subtitle="Your active care team" action="View all" onAction={onOpenPatients} />
          {patients.length ? (
            <div className="compact-patient-list">
              {patients.map((patient) => (
                <button className="compact-patient" key={patient.user_id} onClick={() => onSelectPatient(patient.user_id)}>
                  <Avatar name={patient.full_name} />
                  <span><strong>{patient.full_name}</strong><small>{patient.active_medication_count} active medications</small></span>
                  <ChevronRight size={17} />
                </button>
              ))}
            </div>
          ) : <EmptyState title="Your list is clear" detail="Patients who approve a care-team connection will show here." />}
        </section>
      </div>
      <div className="security-strip"><ShieldCheck size={18} /><span><strong>Patient privacy is protected.</strong> Access is limited to patients with an active, verified care-team relationship.</span></div>
    </>
  );
}

function PatientsPage({
  patients,
  selectedId,
  detail,
  detailLoading,
  query,
  onQuery,
  onSelect,
}: {
  patients: PatientSummary[];
  selectedId: string | null;
  detail: PatientDetail | null;
  detailLoading: boolean;
  query: string;
  onQuery: (value: string) => void;
  onSelect: (id: string) => void;
}) {
  return (
    <div className="patients-layout">
      <section className="panel patient-directory">
        <div className="directory-heading"><div><h2>Patient directory</h2><span>{patients.length} assigned patients</span></div><span className="muted-icon"><UsersRound size={19} /></span></div>
        <label className="search-box"><Search size={17} /><input value={query} onChange={(event) => onQuery(event.target.value)} placeholder="Search name or phone" /></label>
        <div className="directory-list">
          {patients.map((patient) => (
            <button key={patient.user_id} className={`directory-patient ${patient.user_id === selectedId ? "selected" : ""}`} onClick={() => onSelect(patient.user_id)}>
              <Avatar name={patient.full_name} />
              <span className="directory-person"><strong>{patient.full_name}</strong><small>{patient.phone ?? "No phone number"}</small></span>
              <ChevronRight size={17} />
            </button>
          ))}
          {!patients.length && <EmptyState title="No patients found" detail={query ? "Try a different search." : "There are no active patient assignments yet."} />}
        </div>
      </section>
      <section className="panel patient-chart">
        {detailLoading ? <LoadingInline /> : detail ? <PatientChart patient={detail} /> : <EmptyState title="Choose a patient" detail="Select a patient from your directory to view their chart." />}
      </section>
    </div>
  );
}

function PatientChart({ patient }: { patient: PatientDetail }) {
  return (
    <>
      <div className="chart-header">
        <div className="chart-identity"><Avatar name={patient.full_name} large /><div><h2>{patient.full_name}</h2><span>Patient chart</span></div></div>
        <span className="status-pill active"><span />Active patient</span>
      </div>
      <div className="patient-facts">
        <Fact label="Date of birth" value={patient.date_of_birth ? formatDate(patient.date_of_birth) : "Not provided"} />
        <Fact label="Phone" value={patient.phone ?? "Not provided"} />
        <Fact label="Active medications" value={String(patient.medications.length)} />
      </div>
      {patient.accessibility_notes && <div className="clinical-note"><strong>Care notes</strong><p>{patient.accessibility_notes}</p></div>}
      <section className="chart-section">
        <div className="section-title"><div><h3>Current medications</h3><p>Active medication records</p></div><span className="count-badge">{patient.medications.length}</span></div>
        {patient.medications.length ? <div className="medication-list">
          {patient.medications.map((medication) => (
            <article className="medication-card" key={medication.medication_id}>
              <div className="med-icon"><ClipboardList size={18} /></div>
              <div className="med-copy">
                <strong>{medication.medication_name}{medication.strength ? ` · ${medication.strength}` : ""}</strong>
                <span>{medication.dosage_amount != null ? `${medication.dosage_amount} ${medication.dosage_unit ?? ""}` : "Dosage not recorded"}{medication.frequency_text ? ` · ${medication.frequency_text}` : ""}</span>
                {medication.schedule_times.length > 0 && <small>{medication.schedule_times.join(" · ")}</small>}
                {medication.instructions && <small>{medication.instructions}</small>}
              </div>
            </article>
          ))}
        </div> : <EmptyState title="No active medications" detail="No active medications have been recorded." />}
      </section>
      <section className="chart-section">
        <div className="section-title"><div><h3>Symptom reports</h3><p>Most recent patient-reported symptoms</p></div><span className="count-badge">{patient.symptoms.length}</span></div>
        {patient.symptoms.length ? <div className="symptom-list">
          {patient.symptoms.map((symptom) => (
            <article className="symptom-card" key={symptom.id}>
              <div className="symptom-line"><strong>{symptom.symptom_text}</strong><time>{formatDateTime(symptom.reported_at)}</time></div>
              <div className="symptom-meta">{symptom.severity ? <span className="severity">Severity {symptom.severity}/5</span> : <span>Severity not recorded</span>}</div>
              {symptom.clinician_response && <p className="clinician-response"><strong>Clinical response:</strong> {symptom.clinician_response}</p>}
            </article>
          ))}
        </div> : <EmptyState title="No symptom reports" detail="New patient-reported symptoms will appear here." />}
      </section>
    </>
  );
}

function AppointmentsPage({ appointments }: { appointments: DoctorAppointment[] }) {
  const now = Date.now();
  const filtered = appointments.filter((appointment) => appointment.status !== "rescheduled");
  const upcoming = filtered.filter((appointment) => new Date(appointment.ends_at).getTime() >= now);
  const past = filtered.filter((appointment) => new Date(appointment.ends_at).getTime() < now).reverse();
  return (
    <div className="appointments-page">
      <section className="panel">
        <PanelHeading title="Upcoming visits" subtitle="Scheduled and confirmed appointments" />
        {upcoming.length ? <div className="appointment-list full-list">{upcoming.map((appointment) => <AppointmentRow key={appointment.id} appointment={appointment} expanded />)}</div> : <EmptyState title="Nothing scheduled" detail="Upcoming appointments for your assigned patients will appear here." />}
      </section>
      <section className="panel">
        <PanelHeading title="Recent history" subtitle="Appointments from the last 30 days" />
        {past.length ? <div className="appointment-list full-list">{past.map((appointment) => <AppointmentRow key={appointment.id} appointment={appointment} expanded />)}</div> : <EmptyState title="No recent appointments" detail="Completed visit history will appear here." />}
      </section>
    </div>
  );
}

function AppointmentRow({ appointment, expanded = false }: { appointment: DoctorAppointment; expanded?: boolean }) {
  const start = new Date(appointment.starts_at);
  return (
    <article className={`appointment-row ${expanded ? "expanded" : ""}`}>
      <div className="date-block"><strong>{start.toLocaleDateString(undefined, { day: "2-digit" })}</strong><span>{start.toLocaleDateString(undefined, { month: "short" })}</span></div>
      <div className="appointment-info">
        <strong>{appointment.patient_name}</strong>
        <span><Clock3 size={13} /> {formatTime(appointment.starts_at)} – {formatTime(appointment.ends_at)} <i /> {appointmentType(appointment.appointment_type)}</span>
        {expanded && appointment.reason && <small>{appointment.reason}</small>}
        {expanded && appointment.patient_notes && <small className="patient-note"><strong>Patient note:</strong> {appointment.patient_notes}</small>}
        {expanded && appointment.clinician_notes && <small className="patient-note"><strong>Clinical note:</strong> {appointment.clinician_notes}</small>}
      </div>
      <span className={`status-pill ${appointment.status}`}><span />{labelStatus(appointment.status)}</span>
    </article>
  );
}

function SignInPage({ error, onSignIn }: { error: string; onSignIn: (email: string, password: string) => Promise<void> }) {
  const [email, setEmail] = useState("");
  const [password, setPassword] = useState("");
  const [loading, setLoading] = useState(false);
  const [localError, setLocalError] = useState("");
  const submit = async (event: FormEvent<HTMLFormElement>) => {
    event.preventDefault();
    setLoading(true);
    setLocalError("");
    try {
      await onSignIn(email, password);
    } catch (cause) {
      setLocalError(cause instanceof Error ? cause.message : "Sign in failed.");
    } finally {
      setLoading(false);
    }
  };
  return (
    <div className="auth-page">
      <div className="auth-brand brand"><div className="brand-mark"><HeartPulse size={22} strokeWidth={2.5} /></div><div><strong>smartmed</strong><span>CARE PORTAL</span></div></div>
      <main className="auth-card">
        <div className="auth-icon"><ShieldCheck size={23} /></div>
        <div className="eyebrow">DOCTOR WORKSPACE</div>
        <h1>Welcome back</h1>
        <p>Sign in with your verified SmartMed clinician account.</p>
        <form onSubmit={submit}>
          <label>Email address<input type="email" autoComplete="username" required value={email} onChange={(event) => setEmail(event.target.value)} placeholder="doctor@clinic.com" /></label>
          <label>Password<input type="password" autoComplete="current-password" required value={password} onChange={(event) => setPassword(event.target.value)} placeholder="Enter your password" /></label>
          {(error || localError) && <div className="form-error" role="alert">{localError || error}</div>}
          <button className="primary-button" disabled={loading}>{loading ? "Signing in…" : "Sign in securely"}<ChevronRight size={17} /></button>
        </form>
        <div className="auth-footnote"><ShieldCheck size={15} /> Protected with secure sign-in</div>
      </main>
      <span className="auth-caption">SmartMed · Connected care, made clearer.</span>
    </div>
  );
}

function NavButton({ active, icon, label, count, onClick }: { active: boolean; icon: ReactNode; label: string; count?: number; onClick: () => void }) {
  return <button className={`nav-button ${active ? "active" : ""}`} onClick={onClick}>{icon}<span>{label}</span>{count !== undefined && <small>{count}</small>}</button>;
}

function StatCard({ icon, label, value, note, tone }: { icon: ReactNode; label: string; value: number; note: string; tone: string }) {
  return <article className="stat-card"><div className={`stat-icon ${tone}`}>{icon}</div><div className="stat-label">{label}</div><strong className="stat-value">{value}</strong><span className="stat-note">{note}</span></article>;
}

function PanelHeading({ title, subtitle, action, onAction }: { title: string; subtitle: string; action?: string; onAction?: () => void }) {
  return <div className="panel-heading"><div><h2>{title}</h2><p>{subtitle}</p></div>{action && <button className="text-action" onClick={onAction}>{action}<ChevronRight size={15} /></button>}</div>;
}

function Fact({ label, value }: { label: string; value: string }) {
  return <div className="fact"><span>{label}</span><strong>{value}</strong></div>;
}

function Avatar({ name, small = false, large = false }: { name: string; small?: boolean; large?: boolean }) {
  const initials = name.split(/\s+/).filter(Boolean).slice(0, 2).map((part) => part[0]).join("").toUpperCase() || "SM";
  return <span className={`avatar ${small ? "small" : ""} ${large ? "large" : ""}`}>{initials}</span>;
}

function EmptyState({ title, detail }: { title: string; detail: string }) {
  return <div className="empty-state"><div className="empty-icon"><ClipboardList size={20} /></div><strong>{title}</strong><p>{detail}</p></div>;
}

function LoadingPage() {
  return <div className="loading-page"><div className="brand-mark"><HeartPulse size={22} /></div><span>Preparing your secure workspace…</span></div>;
}

function LoadingInline() {
  return <div className="loading-inline"><span className="spinner" /> Loading your clinical workspace…</div>;
}

function NoticePage({ title, message }: { title: string; message: string }) {
  return <div className="notice-page"><div className="auth-icon"><HeartPulse size={23} /></div><h1>{title}</h1><p>{message}</p></div>;
}

function sectionTitle(section: Section) {
  return section === "overview" ? "Overview" : section === "patients" ? "My patients" : "Appointments";
}

function sectionDescription(section: Section) {
  return section === "patients" ? "Review clinical information for patients in your active care team." : "Review your upcoming visits and recent appointment history.";
}

function formatDate(value: string) {
  const date = value.length === 10 ? new Date(`${value}T12:00:00`) : new Date(value);
  return date.toLocaleDateString(undefined, { weekday: "long", month: "long", day: "numeric", year: "numeric" });
}

function formatDateTime(value: string) {
  return new Date(value).toLocaleString(undefined, { month: "short", day: "numeric", hour: "numeric", minute: "2-digit" });
}

function formatTime(value: string) {
  return new Date(value).toLocaleTimeString(undefined, { hour: "numeric", minute: "2-digit" });
}

function appointmentType(value: DoctorAppointment["appointment_type"]) {
  return value === "in_person" ? "In person" : value === "video" ? "Video visit" : "Phone";
}

function labelStatus(value: DoctorAppointment["status"]) {
  return value.replace("_", " ").replace(/^\w/, (letter) => letter.toUpperCase());
}

export default App;
