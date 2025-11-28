import { APIGatewayProxyEvent, APIGatewayProxyResult, Context } from 'aws-lambda';
import { DynamoDB } from 'aws-sdk';

// Interfaces TypeScript
interface StatsResponse {
  code: string;
  originalUrl: string;
  totalVisits: number;
  visitsByDate: { [date: string]: number };
  period: {
    startDate: string;
    endDate: string;
  };
}

interface UrlItem {
  code: string;
  originalUrl: string;
  createdAt?: string;
  totalVisits?: number;
  shortUrl?: string;
  visitsByDate?: { [date: string]: number };
}

interface StatsTableItem {
  code: string;
  originalUrl: string;
  totalVisits: number;
  visitsByDate: { [date: string]: number };
  startDate: string;
  endDate: string;
  lastUpdated: string;
}

interface QueryParams {
  startDate?: string;
  endDate?: string;
}

const dynamodb = new DynamoDB.DocumentClient();

const URLS_TABLE = process.env.URLS_TABLE || '';
const STATS_TABLE = process.env.STATS_TABLE || 'url-shortener-stats-production';

// Headers CORS completos
const corsHeaders = {
  'Access-Control-Allow-Origin': '*',
  'Access-Control-Allow-Methods': 'GET, POST, PUT, DELETE, OPTIONS',
  'Access-Control-Allow-Headers': 'Content-Type, X-Amz-Date, Authorization, X-Api-Key, X-Amz-Security-Token, X-Amz-User-Agent',
  'Access-Control-Allow-Credentials': 'true',
  'Access-Control-Max-Age': '86400'
};

// Función para guardar estadísticas en la tabla de stats
const saveStatsToStatsTable = async (
  code: string,
  originalUrl: string,
  totalVisits: number,
  visitsByDate: { [date: string]: number },
  startDate: string,
  endDate: string
): Promise<void> => {
  try {
    const item: any = {
      code,
      originalUrl,
      totalVisits,
      visitsByDate,
      startDate,
      endDate,
      lastUpdated: new Date().toISOString(),
      date: `${startDate}_${endDate}` // Campo requerido para el range key
    };

    const putParams: DynamoDB.DocumentClient.PutItemInput = {
      TableName: STATS_TABLE,
      Item: item
    };

    await dynamodb.put(putParams).promise();
    
    console.log('Stats saved to stats table:', {
      code,
      totalVisits,
      startDate,
      endDate
    });
  } catch (error) {
    console.error('Error saving stats to stats table:', error);
    // Mejorar el logging para debugging
    console.error('Error details:', {
      code,
      startDate, 
      endDate,
      tableName: STATS_TABLE,
      errorMessage: (error as Error).message
    });
  }
};

export const handler = async (
  event: APIGatewayProxyEvent, 
  context: Context
): Promise<APIGatewayProxyResult> => {
  
  console.log('Event:', JSON.stringify(event, null, 2));
  
  // Manejar preflight OPTIONS request
  if (event.httpMethod === 'OPTIONS') {
    console.log('Handling OPTIONS preflight request');
    return {
      statusCode: 200,
      headers: corsHeaders,
      body: ''
    };
  }
  
  try {
    const code = event.pathParameters?.code;
    const queryParams: QueryParams = event.queryStringParameters || {};
    const { startDate, endDate } = queryParams;

    if (!code) {
      return createResponse(400, { error: 'Code parameter is required' });
    }

    // Verificar que el código existe y obtener los datos
    const urlData = await dynamodb.get({
      TableName: URLS_TABLE,
      Key: { code }
    }).promise();

    if (!urlData.Item) {
      return createResponse(404, { error: 'URL not found' });
    }

    const urlItem = urlData.Item as UrlItem;

    // Obtener visitsByDate directamente de la tabla principal
    const visitsByDateFromTable = urlItem.visitsByDate || {};
    const totalVisitsFromTable = urlItem.totalVisits || 0;

    console.log('Data from URL table:', {
      code,
      totalVisits: totalVisitsFromTable,
      visitsByDate: visitsByDateFromTable,
      visitsByDateCount: Object.keys(visitsByDateFromTable).length
    });

    let finalVisitsByDate: { [date: string]: number };
    let finalTotalVisits: number;

    // Si hay filtros de fecha, aplicar filtrado
    if (startDate || endDate) {
      const filteredData = filterVisitsByDateRange(visitsByDateFromTable, startDate, endDate);
      finalVisitsByDate = filteredData.visitsByDate;
      finalTotalVisits = filteredData.totalVisits;
      
      console.log('After date filtering:', {
        startDate,
        endDate,
        filteredTotalVisits: finalTotalVisits,
        filteredVisitsByDateCount: Object.keys(finalVisitsByDate).length,
        filteredVisitsByDate: finalVisitsByDate
      });
    } else {
      // Sin filtros, usar los datos directamente de la tabla
      finalVisitsByDate = visitsByDateFromTable;
      finalTotalVisits = totalVisitsFromTable;
    }

    const periodStartDate = startDate || 'all';
    const periodEndDate = endDate || 'all';

    // ✅ GUARDAR EN LA TABLA DE STATS
    await saveStatsToStatsTable(
      code,
      urlItem.originalUrl,
      finalTotalVisits,
      finalVisitsByDate,
      periodStartDate,
      periodEndDate
    );

    const response: StatsResponse = {
      code,
      originalUrl: urlItem.originalUrl,
      totalVisits: finalTotalVisits,
      visitsByDate: finalVisitsByDate,
      period: {
        startDate: periodStartDate,
        endDate: periodEndDate
      }
    };

    console.log('Final response:', {
      code,
      totalVisits: finalTotalVisits,
      visitsByDateCount: Object.keys(finalVisitsByDate).length,
      visitsByDate: finalVisitsByDate,
      period: {
        startDate: periodStartDate,
        endDate: periodEndDate
      }
    });

    return createResponse(200, response);

  } catch (error) {
    console.error('Error:', error);
    return createResponse(500, { 
      error: 'Internal server error', 
      details: (error as Error).message 
    });
  }
};

// Función para filtrar visitsByDate por rango de fechas
function filterVisitsByDateRange(
  visitsByDate: { [date: string]: number }, 
  startDate?: string, 
  endDate?: string
): { visitsByDate: { [date: string]: number }; totalVisits: number } {
  
  const filteredVisitsByDate: { [date: string]: number } = {};
  let totalVisits = 0;

  console.log('Filtering dates:', {
    allDates: Object.keys(visitsByDate),
    startDate,
    endDate
  });

  Object.keys(visitsByDate).forEach(date => {
    const visits = visitsByDate[date] || 0;
    
    // Aplicar filtros de fecha
    let shouldIncludeDate = true;

    if (startDate && date < startDate) {
      shouldIncludeDate = false;
      console.log(`Excluding date ${date} because it's before startDate ${startDate}`);
    }

    if (endDate && date > endDate) {
      shouldIncludeDate = false;
      console.log(`Excluding date ${date} because it's after endDate ${endDate}`);
    }

    if (shouldIncludeDate) {
      filteredVisitsByDate[date] = visits;
      totalVisits += visits;
      console.log(`Including date ${date} with ${visits} visits`);
    }
  });

  // Ordenar las fechas cronológicamente
  const sortedVisitsByDate: { [date: string]: number } = {};
  Object.keys(filteredVisitsByDate)
    .sort((a, b) => a.localeCompare(b))
    .forEach(date => {
      const visitCount = filteredVisitsByDate[date];
      if (visitCount !== undefined) {
        sortedVisitsByDate[date] = visitCount;
      }
    });

  console.log('Filtering result:', {
    originalDatesCount: Object.keys(visitsByDate).length,
    filteredDatesCount: Object.keys(sortedVisitsByDate).length,
    calculatedTotalVisits: totalVisits,
    filteredDates: Object.keys(sortedVisitsByDate)
  });

  return {
    visitsByDate: sortedVisitsByDate,
    totalVisits
  };
}

function createResponse(statusCode: number, body: any): APIGatewayProxyResult {
  return {
    statusCode,
    headers: {
      ...corsHeaders,
      'Content-Type': 'application/json'
    },
    body: JSON.stringify(body)
  };
}