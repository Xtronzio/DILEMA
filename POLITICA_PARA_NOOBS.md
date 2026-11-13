# DILEMA · POLÍTICA PARA NOOBS

Módulo de debate cívico y comparativa documental del 29N 2026, desarrollado de forma **aislada** del debate convencional y de JUEGO.

## Experiencia

1. El anfitrión crea una sala de **1 a 20 personas**, comparte el enlace y comienza el pulso inicial de seis Hot Points.
2. El moderador `politics-moderator` solicita a la IA una pregunta nueva de alternativas A/B y una repregunta de tensión. Si falla la IA, selecciona una de las preguntas del banco editorial sin repetir en la sala.
3. En el **pulso inicial** todos votan A/B/Depende de forma privada; los porcentajes se presentan cuando han votado todos. En el **debate** ya no hay una votación simultánea: cada pregunta genera un sorteo de orden de intervención y cada miembro registra una sola respuesta A/B/Depende, con argumento escrito opcional, cuando le toca.
4. El resto del grupo puede debatir oralmente; solo quien tiene el turno registra su propia respuesta. Al guardar, pasa automáticamente al siguiente miembro del orden sorteado. La IA puede plantear objeciones, puntos ciegos y otras miradas. En modo individual existen además hasta cinco intercambios por escrito con DILEMA.
5. Cuando todos han respondido a la misma pregunta, se puede abrir una nueva pregunta con **otro sorteo**, o someter a la mesa la decisión de terminar y revelar siglas y **documentos electorales verificables**.
6. El mapa muestra porcentajes de votos del pulso y respuestas registradas de cada pregunta del debate. No puntúa ni recomienda candidatos, partidos ni voto.

## Datos y seguridad

- GitHub Pages aloja únicamente HTML/JS públicos; **sin claves secretas**.
- La IA se llama mediante la función autenticada de Supabase, con clave OpenAI en los secretos del servidor.
- Tablas separadas `private.politics_*`, RLS activo y permisos directos revocados. Los votos iniciales se muestran agregados. Los argumentos del debate se almacenan con apodos solo para las personas participantes en esa sala, y la IA puede usar fragmentos sin nombres para repreguntar.
- Creación/acceso requiere consentimiento explícito. No se pide DNI, correo, perfil político ni dirección.
- El anfitrión al salir cierra y elimina sala, votos y respuestas. La salida de un invitado elimina sus registros y reajusta el orden pendiente.
- Limpieza automática programada para no superar aproximadamente 72 horas. El texto registrado como respuesta sí se guarda temporalmente en Supabase; los mensajes del diálogo individual enviados a la IA no se guardan en la base de datos.
- Las peticiones de IA se limitan por sala/ronda, usuario y cupo diario global.
- Para una apertura pública destinada a menores o a un público amplio, pendiente de revisión legal y de privacidad.

## Fuentes

- Las tarjetas de propuestas (30 en esta versión) corresponden a documentos oficiales localizados de **PP, Vox, PNV y contrato electoral simplificado de SALF**, con enlaces a PDF y páginas.
- El resto de candidaturas principales (PSOE, Frente Amplio, Podemos, EH Bildu y PCTE) se indica expresamente como pendiente, sin atribuirles medidas no verificadas.
- Cada Hot Point proporciona contexto documental a la IA cuando existe. Una pregunta sobre política pública no es una promesa atribuida a una formación.
- Actualizar las fuentes requiere revisar primero el PDF oficial y registrar su página. No inventar propuestas ni inferirlas por ideología.

## Verificaciones

**Automáticas/estructura realizadas**
- Parseo JavaScript sin error.
- Todos los identificadores de UI utilizados por el JS existen en HTML.
- Pruebas transaccionales SQL con rollback: votación individual, 2 participantes, votos ocultos hasta cerrar ronda, pregunta diferente en segunda ronda, turnos, repregunta compartida, revelación de datos, consentimiento, límite de solicitudes de IA y eliminación de sala.
- Inspección de permisos: RPCs sin consentimiento y voto público anónimo no disponibles.

**Pruebas manuales antes de ampliar el acceso**
- Confirmar inicio de sesión anónimo en Safari iOS.
- Crear sala de 1 persona, votar, debatir por escrito y abrir una nueva ronda.
- Crear sala de 2 o más desde navegadores o dispositivos independientes; probar enlace/código, estado de votos, turnos y revelación.
- Comprobar que el proveedor IA responde realmente desde el entorno web y que la caída se resuelve con el banco editorial sin bloquear la sala.
- Verificar accesibilidad visual y UX con menores bajo supervisión.

**No se realizan tests de afinidad ideológica ni se ofrece recomendación de voto.**


## Actualización R125: primer pulso, edades y mesa por turnos

- Al abrir una sala, el anfitrión indica **una edad por participante**; el servidor conserva únicamente el tramo de lenguaje (`teen_early`, `teen`, `mixed`, `adult`), no las edades exactas.
- **Primero seis preguntas rápidas de seis Hot Points distintos**. Todos votan A/B/Depende en cada pregunta y todavía no se abre el debate. La mesa puede comparar los resultados.
- El anfitrión inicia la **fase de debate profundo**. La mecánica de esta línea fue reemplazada en R126: cada pregunta sortea el orden y cada participante registra su elección y argumento por turnos, no con una segunda votación simultánea.
- **Solo la persona que tiene el turno** puede registrar su propia respuesta y solicitar Contradíceme/Punto ciego/Otra mirada. Desde R126 el turno pasa automáticamente al registrar; no se puede saltar una respuesta pendiente. Una vez registrados todos, la última persona puede abrir otra pregunta o proponer finalizar. Estas condiciones se verifican en SQL.
- La persona en turno puede proponer finalizar; **cada participante vota sí/no**. Con mayoría absoluta de respuestas afirmativas y tras votar todos, se cierra; los empates o rechazos mantienen el debate.
- **DILEMA dicta sentencia** al cierre: resumen descriptivo de los temas, discrepancias y dudas del grupo a partir de resultados agregados; no recomienda partidos ni deduce tendencias de voto. Se conservan fuentes oficiales en la revelación.
- Hay **96 situaciones nuevas redactadas para principiantes**, además del banco editorial anterior, y generación dinámica de preguntas que evita repeticiones en la misma sala.
- Pantalla de debate `100dvh` con scroll interno de las preguntas, cabecera fija de la propia interfaz y herramientas/entrada debajo, sin desplazamiento de toda la página.
- CSS mantiene la codificación de colores de los estados y botón **OTRA PREGUNTA** en naranja `#FF9F43`.
- Las pruebas automatizadas con rollback han verificado pulso de seis preguntas, paso a debate, turno individual, prohibición de intervenir fuera de turno, consenso de cierre y escenario de empate.
- **Pendiente:** prueba manual en Safari con varios teléfonos, verificación visual de teclado/área segura y revisión de privacidad antes de ampliar distribución.


## Actualización R126: respuestas dirigidas por sorteo

- **Primer pulso (sin cambios):** seis Hot Points votados por todos, con resultados agregados.
- **Debate por preguntas:** cada nueva pregunta produce un orden aleatorio de todos los miembros. DILEMA llama al primero y muestra quién tiene la palabra.
- **Una respuesta por miembro y pregunta:** elección A/B/Depende y texto opcional de hasta 700 caracteres. Solo el usuario autenticado que figura en ese turno puede guardarla. Los demás pueden participar oralmente, sin registrar una respuesta en su nombre.
- **Turno automático:** después de guardar, cambia al siguiente integrante sorteado. Al completar todos, la última persona puede abrir otra pregunta o proponer que la mesa cierre mediante votación.
- **Historial:** conserva cada pregunta con respuestas firmadas por el apodo y sus argumentos, visibles exclusivamente para los integrantes de esa sala. La información desaparece al cerrar la sala o con la limpieza automática.
- **IA:** genera nuevas preguntas considerando únicamente extractos sin nombre de los argumentos voluntariamente registrados, además de la temática y las propuestas electorales verificadas. Nunca se presentan como hechos comprobados las afirmaciones personales.
- **Protecciones:** funciones SQL autenticadas que revisan la pertenencia a sala, turno sorteado, unicidad por pregunta y estado de ronda; las tablas privadas tienen RLS y ningún acceso directo público.
- **QA:** pruebas SQL transaccionales de cuatro participantes para sorteo completo, bloqueo de participación fuera de turno, registro único de cada respuesta, cierre por mayoría, historial y nueva ronda. También se probó la salida de un participante durante una pregunta.
- **Pendiente de validar manualmente:** experiencia en Safari móvil con varios dispositivos y resultado real de la API de IA. El frontend es una beta.

