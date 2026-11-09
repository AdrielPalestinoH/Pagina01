
// PNT-01: Auto-Matching y Conciliación
function ejecutarAutoMatching() {
    alert("Ejecutando algoritmo heurístico de emparejamiento (Endpoint: POST /api/v1/reconciliations/auto-match)...\n¡Coincidencias encontradas!");
    
    let chkBanco = document.querySelectorAll('.chk-banco');
    let chkFactura = document.querySelectorAll('.chk-factura');
    
    if(chkBanco.length > 0 && chkFactura.length > 1) {
        chkBanco[1].checked = true; // -32150
        chkFactura[1].checked = true; // 20000
        chkFactura[2].checked = true; // 12150
        calcularDiferencia();
    }
}

function calcularDiferencia() {
    let lblDiferencia = document.getElementById('lbl-diferencia');
    let badgeEstado = document.getElementById('badge-estado');
    let btnConciliar = document.getElementById('btn-conciliar');
    if(!lblDiferencia) return;
    
    // Sumar bancos (vienen en negativo, usamos valor absoluto)
    let sumBanco = 0;
    document.querySelectorAll('.chk-banco:checked').forEach(e => sumBanco += Math.abs(parseFloat(e.value)));
    
    // Sumar facturas
    let sumFactura = 0;
    document.querySelectorAll('.chk-factura:checked').forEach(e => sumFactura += parseFloat(e.value));
    
    let diferencia = Math.abs(sumBanco - sumFactura);
    let tolerancia = parseFloat(document.getElementById('tolerancia').value);
    
    lblDiferencia.innerText = diferencia.toFixed(2);
    
    if(sumBanco === 0 && sumFactura === 0) {
        badgeEstado.innerText = "ESPERANDO SELECCIÓN";
        badgeEstado.className = "badge badge-warning";
        badgeEstado.style.backgroundColor = "";
        btnConciliar.disabled = true;
    } else if (diferencia <= tolerancia) {
        badgeEstado.innerText = "COINCIDENCIA EXACTA VÁLIDA";
        badgeEstado.className = "badge badge-success";
        badgeEstado.style.backgroundColor = "";
        btnConciliar.disabled = false;
    } else {
        badgeEstado.innerText = "DISCREPANCIA SUPERADA";
        badgeEstado.className = "badge badge-danger";
        btnConciliar.disabled = true;
    }
}

document.addEventListener('change', function(e) {
    if(e.target.classList.contains('chk-banco') || e.target.classList.contains('chk-factura')) {
        calcularDiferencia();
    }
});

function conciliar() {
    let btnConciliar = document.getElementById('btn-conciliar');
    if(btnConciliar.disabled) return;
    
    if(confirm("¿Está seguro de aplicar la conciliación transaccional? Esta acción bloquea los registros contra modificaciones contables (POST /api/v1/reconciliations/manual).")){
        alert("Conciliación guardada exitosamente. Registros bloqueados.");
    }
}

// PNT-02: Procesamiento de archivos
function actualizarNombreArchivo(input) {
    let fileNameDisplay = document.getElementById('nombreArchivoSel');
    if(input.files.length > 0) {
        fileNameDisplay.innerText = "Archivo seleccionado: " + input.files[0].name;
    } else {
        fileNameDisplay.innerText = "";
    }
}

function procesarArchivo() {
    let file = document.getElementById('fileExtracto').files[0];
    if(!file) {
        alert("Por favor, arrastra o selecciona un archivo .csv o .txt primero.");
        return;
    }
    
    let ext = file.name.split('.').pop().toLowerCase();
    if(ext !== 'csv' && ext !== 'txt') {
        alert("Error de formato: Sólo se permiten archivos .csv o .txt (máximo 10MB).");
        return;
    }
    
    alert("Procesando archivo: " + file.name + "\nEndpoint: POST /api/v1/bank-statements/upload\n\nValidación sintáctica exitosa.");
}

// PNT-03: Facturas
function guardarFactura() {
    let fechaEmision = new Date(document.getElementById('fechaEmision').value);
    let fechaVenc = new Date(document.getElementById('fechaVenc').value);
    let clabe = document.getElementById('clabe').value;
    
    if(fechaVenc < fechaEmision) {
        alert("Error de validación: La fecha de vencimiento no puede ser anterior a la fecha de emisión.");
        return;
    }
    
    if(clabe.length !== 18) {
        alert("Error de validación: La CLABE interbancaria debe tener exactamente 18 dígitos.");
        return;
    }
    
    alert("Factura validada y enviada al backend (POST /api/v1/invoices) correctamente.");
    document.getElementById('form-factura').reset();
}

// PNT-04: Dispersión
function autorizarLote() {
    // Cuadro modal de alta visibilidad indicando irreversibilidad
    if(confirm("⚠ ADVERTENCIA CRÍTICA DE DISPERSIÓN MONETARIA ⚠\n\nLa dispersión bancaria es una acción IRREVERSIBLE.\n¿Autoriza la transferencia de fondos por un monto total de $320,000.00 MXN hacia 3 proveedores para el lote L-2026-09-A?")) {
        alert("Lote autorizado. Dispersión en proceso (Endpoint: POST /api/v1/payment-batches/{id}/authorize).");
    }
}

function rechazarLote() {
    let motivo = prompt("Por favor, ingrese el motivo del rechazo del lote (mínimo 15 caracteres requeridos):");
    if(motivo && motivo.length >= 15) {
        alert("Lote rechazado correctamente. Motivo registrado en auditoría.");
    } else {
        alert("Validación fallida: Motivo inválido o longitud menor a 15 caracteres. Rechazo cancelado.");
    }
}

// PNT-05: Reportes
function generarReporte() {
    let fInicio = new Date(document.getElementById('repInicio').value);
    let fFin = new Date(document.getElementById('repFin').value);
    
    if(fFin < fInicio) {
        alert("Error de filtro: La fecha final (Fin) es anterior a la fecha de inicio.");
        return;
    }
    
    document.getElementById('resultadosReporte').style.display = 'block';
}

// Inicialización de funciones necesarias al cargar la página
window.onload = function() {
    calcularDiferencia();
}
